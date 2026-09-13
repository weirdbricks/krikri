#!/usr/bin/env crystal

# krikri - ad-hoc CLI (equivalent of `ansible`)
#
# The `ansible` counterpart to krikri-playbook.cr's `ansible-playbook`
# reimplementation: runs exactly ONE module against a pattern of
# inventory hosts, matching real ansible-core's own `ansible <pattern>
# -m <module> -a <args>` ad-hoc surface - a separate binary, not a
# krikri-playbook subcommand, for the same reason real Ansible ships
# `ansible` and `ansible-playbook` as two distinct executables rather
# than folding ad-hoc mode into ansible-playbook's own CLI. Reuses the
# exact same TaskExecutor/PluginManager/InventoryParser machinery as
# the playbook engine (connection handling, become, check mode, forks,
# facts) - only the CLI surface and result-display format differ, via
# TaskExecutor's `adhoc: true` flag (see task_executor/executor.cr and
# task_executor/result_display.cr's display_adhoc_result).
#
# The option surface mirrors real `ansible`'s own --help (verified
# against ansible-core 2.19.4): playbook-only flags (tags, --syntax-check,
# --list-tasks, ...) are deliberately absent, while everything real
# ad-hoc mode accepts is accepted here. Where krikri-playbook.cr
# implements an equivalent flag, the exact same wiring is reused
# (CliOptions for the ssh-invocation flags, host vars for the
# "set this connection variable for every host" flags, VaultCli for the
# password prompts, Vault for the vault sources).

require "option_parser"
require "colorize"
require "./src/krikri/version"
require "./src/krikri/playbook_parser"
require "./src/krikri/inventory_parser"
require "./src/krikri/cli_options"
require "./src/krikri/extra_vars_parser"
require "./src/krikri/vault"
require "./src/krikri/vault_cli"
require "./src/krikri/task_executor"

# Colorize is tty-gated by default (non-tty output stays plain, matching
# real ansible's isatty check); ANSIBLE_FORCE_COLOR=1 forces it back on
# for the same piped-output use cases real ansible supports it for.
Colorize.enabled = true if ENV["ANSIBLE_FORCE_COLOR"]? == "1"

pattern = ""
module_name = "command"
module_args = ""
inventory_file = "inventory.ini"
remote_user = nil
become = false
become_user = nil
become_method_override = nil.as(String?)
private_key_file = nil.as(String?)
connection_override = nil.as(String?)
check_mode = false
diff_mode = false
forks = 5
limit_hosts = ""
verbose = false
# Stacked -v/-vv/-vvv verbosity, computed the same way krikri-playbook.cr
# does: stripped out of the args array here because Crystal's OptionParser
# treats single-dash multi-char flags like long options, and registering
# several sharing the "-v" prefix hits real ambiguity bugs (see
# krikri-playbook.cr's own comment on this).
verbosity_level = ARGV.select { |arg| arg =~ /\A-v+\z/ }.sum(&.size.-(1))
cli_args = ARGV.reject { |arg| arg =~ /\A-v+\z/ }
ask_pass = false
ask_become_pass = false
ask_vault_pass = false
connection_password_file = nil.as(String?)
become_password_file = nil.as(String?)
vault_id_args = [] of String
vault_password_file = nil.as(String?)
flush_cache = false
list_hosts_only = false
module_path_args = [] of String
extra_vars_args = [] of String
playbook_dir_override = nil.as(String?)
task_timeout = nil.as(Int32?)
background_seconds = 0
poll_interval = 0
one_line = false
tree_dir = nil.as(String?)

begin
  OptionParser.parse(cli_args) do |parser|
    parser.banner = "Usage: ansible <pattern> [options]"

    parser.on("-m MODULE", "--module-name=MODULE", "Module name to execute (default: command)") do |mat|
      module_name = mat
    end

    parser.on("-a ARGS", "--args=ARGS", "Module arguments") do |aval|
      module_args = aval
    end

    parser.on("-i INVENTORY", "--inventory=INVENTORY", "Specify inventory file") do |inv|
      inventory_file = inv
    end

    parser.on("-u USER", "--user=USER", "Connect as this remote user") do |uval|
      remote_user = uval
    end

    parser.on("-b", "--become", "Run operations with become (privilege escalation)") do
      become = true
    end

    parser.on("--become-user=USER", "Run operations as this user (default: root)") do |uval|
      become_user = uval
    end

    parser.on("--become-method=METHOD", "Privilege escalation method to use (sets ansible_become_method)") do |mat|
      become_method_override = mat
    end

    parser.on("--private-key=FILE", "--key-file=FILE", "SSH private key to connect with (sets ansible_ssh_private_key_file)") do |fval|
      private_key_file = fval
    end

    parser.on("-k", "--ask-pass", "Ask for the connection password") do
      ask_pass = true
    end

    parser.on("-K", "--ask-become-pass", "Prompt for the privilege escalation password") do
      ask_become_pass = true
    end

    parser.on("--connection-password-file=FILE", "--conn-pass-file=FILE", "Read the connection password from this file") do |fval|
      connection_password_file = fval
    end

    parser.on("--become-password-file=FILE", "--become-pass-file=FILE", "Read the privilege escalation password from this file") do |fval|
      become_password_file = fval
    end

    parser.on("-c TYPE", "--connection=TYPE", "Connection type to use (sets ansible_connection)") do |itm|
      connection_override = itm
    end

    parser.on("-T SECONDS", "--timeout=SECONDS", "SSH connection timeout in seconds (default 10)") do |tval|
      Krikri::CliOptions.timeout = tval.to_i? || 10
    end

    parser.on("--ssh-common-args=ARGS", "Extra arguments appended to every ssh invocation") do |aval|
      Krikri::CliOptions.ssh_common_args = aval
    end

    parser.on("--ssh-extra-args=ARGS", "Extra arguments appended to every ssh invocation") do |aval|
      Krikri::CliOptions.ssh_extra_args = aval
    end

    parser.on("--scp-extra-args=ARGS", "Extra arguments appended to every scp invocation") do |aval|
      Krikri::CliOptions.scp_extra_args = aval
    end

    parser.on("--sftp-extra-args=ARGS", "Accepted for compatibility; this engine never invokes sftp") do |aval|
      Krikri::CliOptions.sftp_extra_args = aval
    end

    parser.on("-M PATH", "--module-path=PATH", "Accepted for compatibility; modules here are compiled binaries, not a search path") do |mat|
      module_path_args << mat
    end

    parser.on("--vault-id=ID", "Vault identity as label@source (a password file, or @prompt); repeatable") do |v|
      vault_id_args << v
    end

    parser.on("--vault-password-file=FILE", "Vault password file") do |file|
      vault_password_file = file
    end

    # Real Ansible's own alias for --vault-password-file (ansible-core
    # 2.19.4's --help lists both spellings together).
    parser.on("--vault-pass-file=FILE", "Alias for --vault-password-file") do |file|
      vault_password_file = file
    end

    parser.on("-J", "--ask-vault-password", "Prompt for the vault password") do
      ask_vault_pass = true
    end

    parser.on("--ask-vault-pass", "Prompt for the vault password") do
      ask_vault_pass = true
    end

    parser.on("--flush-cache", "Clear the fact cache before running (this engine keeps facts in memory per run, so there is nothing persisted to clear)") do
      flush_cache = true
    end

    parser.on("--list-hosts", "List the matched hosts, without executing anything") do
      list_hosts_only = true
    end

    parser.on("--playbook-dir=BASEDIR", "Substitute playbook directory; sets the relative path for roles/, group_vars/ etc., since ad-hoc mode has no playbook of its own") do |basedir|
      playbook_dir_override = basedir
    end

    parser.on("--task-timeout=SECONDS", "Set the timeout of the task in seconds (accepted; not yet enforced by this engine)") do |tval|
      task_timeout = tval.to_i?
    end

    parser.on("-B SECONDS", "--background=SECONDS", "Run asynchronously, failing after X seconds (default=N/A)") do |bval|
      background_seconds = bval.to_i? || 0
    end

    parser.on("-P POLL_INTERVAL", "--poll=POLL_INTERVAL", "Set the poll interval if using -B (default 15)") do |pval|
      poll_interval = pval.to_i? || 15
    end

    parser.on("-C", "--check", "Don't make changes; predict changes instead (dry-run)") do
      check_mode = true
    end

    parser.on("-D", "--diff", "Show file differences when changing files") do
      diff_mode = true
    end

    parser.on("-o", "--one-line", "Condense output") do
      one_line = true
    end

    parser.on("-t TREE", "--tree=TREE", "Log output to this directory") do |tval|
      tree_dir = tval
    end

    parser.on("-e EXTRA_VARS", "--extra-vars=EXTRA_VARS", "Set additional variables as key=value, JSON, or @file (highest precedence; repeatable)") do |e|
      extra_vars_args << e
    end

    parser.on("-f FORKS", "--forks=FORKS", "Run against up to FORKS hosts concurrently (default: 5)") do |fval|
      forks = fval.to_i? || 5
    end

    parser.on("-l SUBSET", "--limit=SUBSET", "Limit to specific hosts") do |subset|
      limit_hosts = subset
    end

    parser.on("-v", "--verbose", "Verbose output (stacks: -vv, -vvv, ...)") do
      verbose = true
    end

    parser.on("--version", "Show version information") do
      puts Krikri.version_info
      exit
    end

    parser.on("-h", "--help", "Show this help") do
      puts parser
      puts ""
      puts "Examples:"
      puts "  ansible all -m ping"
      puts "  ansible webservers -a 'uptime'"
      puts "  ansible all -m command -a 'systemctl status nginx'"
      puts "  ansible all -m copy -a 'src=foo.conf dest=/etc/foo.conf' -b"
      puts "  ansible db -i inventory.ini -m service -a 'name=postgresql state=restarted' -b"
      exit
    end

    parser.unknown_args do |args|
      if args.size == 1
        pattern = args[0]
      else
        puts "Error: Please specify exactly one host pattern"
        puts parser
        exit 1
      end
    end
  end
rescue ex : OptionParser::InvalidOption
  puts "Error: #{ex.message}".colorize(:red)
  puts ""
  puts "Run 'ansible --help' for usage information"
  exit 1
rescue ex : Exception
  puts "Error: #{ex.message}".colorize(:red)
  exit 1
end

if pattern.empty?
  puts "Error: A host pattern is required"
  puts "Usage: ansible <pattern> [options]"
  puts "Try 'ansible --help' for more information"
  exit 1
end

# --vault-id label@source, processed exactly as krikri-playbook.cr does
# it: the source is a password FILE, or "prompt" to ask. An unlabeled
# `--vault-id file` is the default identity.
vault_id_args.each do |spec|
  label, _, source = spec.partition('@')
  if source.empty?
    label, source = "default", label
  end

  secret =
    if source == "prompt"
      print "Vault password (#{label}): "
      Krikri::VaultCli.prompt_password
    elsif File.exists?(source)
      File.read(source).strip
    else
      puts "Error: vault-id source not found: #{source}".colorize(:red)
      exit 1
    end

  Krikri::Vault.add_vault_id(label, secret)
end

if password_file = vault_password_file
  Krikri::Vault.password = File.read(password_file).strip
elsif ask_vault_pass
  Krikri::Vault.password = Krikri::VaultCli.prompt_password
end

# Resolve module_name to its AVAILABLE_PLUGINS FQCN, same as a playbook
# task would - the plugin binary is looked up by FQCN, and real ansible
# accepts a bare module name here too (`ansible all -m ping`).
resolved_module = Krikri::PlaybookParser.resolve_module_name(module_name)
unless resolved_module
  puts "Error: Module not found or not supported: #{module_name}".colorize(:red)
  exit 1
end

inventory = nil
begin
  inventory = Krikri::InventoryParser.parse(inventory_file)
rescue ex
  puts "Error loading inventory:".colorize(:red).bold
  puts "  #{ex.message}".colorize(:red)
  puts ""
  puts "Please check that your inventory file exists and is properly formatted.".colorize(:yellow)
  puts "Use -i flag to specify a different inventory file.".colorize(:yellow)
  exit 1
end
inventory = inventory || raise "BUG: inventory not set"

hosts = inventory.get_hosts(pattern)

unless limit_hosts.empty?
  limit_names = inventory.get_hosts(limit_hosts).map(&.name).to_set
  hosts = hosts.select { |host| limit_names.includes?(host.name) }
end

if list_hosts_only
  puts "No hosts matched, nothing to do".colorize(:yellow) if hosts.empty?
  puts "  hosts (#{hosts.size}):"
  hosts.each { |host| puts "    #{host.name}" }
  exit 0
end

if hosts.empty?
  puts "Error: No hosts matched: #{pattern}".colorize(:red)
  exit 1
end

if user = remote_user
  hosts.each(&.user=(user))
end

# The connection/become flags are, in real Ansible, exactly "set this
# connection variable for every host" - the same wiring
# krikri-playbook.cr uses (applied as host vars on top of whatever the
# inventory said). The hosts here are the same objects the executor and
# PluginManager's connection setup read, so these take effect everywhere.
if conn = connection_override
  hosts.each { |host| host.vars["ansible_connection"] = JSON::Any.new(conn) }
end
if key_file = private_key_file
  hosts.each { |host| host.vars["ansible_ssh_private_key_file"] = JSON::Any.new(key_file) }
end
# --become-method has no task field, and ansible_become_method IS a
# documented Ansible variable, so it stays a host var (same reasoning as
# krikri-playbook.cr's).
if become_method_value = become_method_override
  hosts.each { |host| host.vars["ansible_become_method"] = JSON::Any.new(become_method_value) }
end

# The *-password-file flags are the non-interactive form of -k/-K.
if conn_pw_file = connection_password_file
  hosts.each { |host| host.vars["ansible_password"] = JSON::Any.new(File.read(conn_pw_file).strip) }
end
if become_pw_file = become_password_file
  hosts.each { |host| host.vars["ansible_become_password"] = JSON::Any.new(File.read(become_pw_file).strip) }
end

if ask_pass
  print "SSH password: "
  password = Krikri::VaultCli.prompt_password
  hosts.each { |host| host.vars["ansible_password"] = JSON::Any.new(password) }
end
if ask_become_pass
  print "BECOME password: "
  password = Krikri::VaultCli.prompt_password
  hosts.each { |host| host.vars["ansible_become_password"] = JSON::Any.new(password) }
end

extra_vars = {} of String => JSON::Any
unless extra_vars_args.empty?
  begin
    extra_vars = Krikri::ExtraVarsParser.parse(extra_vars_args)
  rescue ex : Krikri::ExtraVarsParser::Error
    puts "Error: #{ex.message}".colorize(:red)
    exit 1
  end
end

# --flush-cache clears any persisted fact cache before the run. This
# engine keeps facts only in memory (the ad-hoc path never gathers any -
# see gather_facts: false below), so there is nothing persisted to
# discard; the flag is accepted and correct, it simply has nothing older
# to clear. Same reasoning as krikri-playbook.cr's own --flush-cache.
_ = flush_cache
# --task-timeout: real Ansible enforces a per-task wall-clock timeout.
# This engine has no task-level enforcement point yet, so the flag is
# accepted (and parses/validates as an integer) but not enforced.
_ = task_timeout
# -P/--poll only matters alongside -B; this engine's async support runs
# the module detached and polls the job to completion internally (see
# TaskExecutor's async handling), so the interval itself is not
# configurable - the flag is accepted for command-line parity.
_ = poll_interval

Krikri::ResultDisplay.adhoc_oneline = true if one_line
Krikri::ResultDisplay.adhoc_tree_dir = tree_dir if tree_dir

task = Krikri::Task.new(name: "ansible ad-hoc command", module_name: resolved_module)
task.params = Krikri::PlaybookParser.parse_adhoc_params(resolved_module, module_args)
task.become = become
task.become_user = become_user
# -B/--background: real ad-hoc mode turns this into `async: SECONDS` on
# the single generated task (verified against ansible-core 2.19.4's
# cli/adhoc.py _play_ds). The engine already implements task-level async
# for playbooks, so setting the same field gets genuine async execution
# (module runs detached, job polled to completion) rather than a
# half-working ad-hoc-specific reimplementation.
task.async_seconds = background_seconds if background_seconds > 0

Krikri::PluginManager.verbose = verbose

# Build the one throwaway Play/Playbook this ad-hoc task needs, purely to
# reuse PluginManager's existing batch-upload pass (pre-uploads the one
# module binary to every matched remote host up front, same as a real
# playbook run) instead of duplicating its per-host connection-dedup
# logic here.
play = Krikri::Play.new(name: "ansible ad-hoc", hosts: pattern)
play.tasks = [task]
play.gather_facts = false
playbook = Krikri::Playbook.new(path: "<ad-hoc>")
playbook.plays = [play]
# A host the batch-upload pass cannot reach is reported (PluginManager
# prints the UNREACHABLE! fatal line itself) and then handed to the
# executor, which reports each task against it as unreachable without
# re-attempting SSH - the exact contract krikri-playbook.cr already
# uses. Discarding this return value used to leave the host in `hosts`,
# where the per-task lazy-upload path raised an uncaught exception that
# killed the whole process instead of reporting and skipping.
unreachable_hosts = Krikri::PluginManager.batch_upload_plugins_for_playbook(playbook, inventory, forks)

# The override var is captured by the OptionParser closure, so its type
# isn't narrowed here - copy it into a plain local first.
playbook_dir_effective = "."
if basedir = playbook_dir_override
  playbook_dir_effective = basedir
end

executor = Krikri::TaskExecutor.new(
  hosts: hosts,
  tasks: [task],
  check_mode: check_mode,
  diff_mode: diff_mode,
  verbosity: verbosity_level,
  gather_facts: false,
  inventory: inventory,
  forks: forks,
  extra_vars: extra_vars,
  # Real Ansible's playbook_dir magic var for an ad-hoc run defaults to
  # the working directory (TaskExecutor's own default); --playbook-dir
  # substitutes it explicitly.
  playbook_dir: playbook_dir_effective,
  unreachable_hosts: unreachable_hosts.to_set,
  adhoc: true
)

executor.run

# Same exit-code convention krikri-playbook.cr uses: unreachable hosts
# exit 4 (ahead of a failed host's 2), only clean runs exit 0. A host
# reported unreachable by the batch pass shows up here through the
# executor's own per-task unreachable booking.
any_unreachable = executor.results.values.any? { |host_stats| (host_stats["unreachable"]? || 0) > 0 }
any_failed = executor.results.values.any? { |host_stats| (host_stats["failed"]? || 0) > 0 }
exit(4) if any_unreachable
exit(any_failed ? 2 : 0)
