#!/usr/bin/env crystal

# Crystal Play - `ansible` ad-hoc CLI
#
# The `ansible` counterpart to crystal-play.cr's `ansible-playbook`
# reimplementation: runs exactly ONE module against a pattern of
# inventory hosts, matching real ansible-core's own `ansible <pattern>
# -m <module> -a <args>` ad-hoc surface - a separate binary, not a
# crystal-ansible subcommand, for the same reason real Ansible ships
# `ansible` and `ansible-playbook` as two distinct executables rather
# than folding ad-hoc mode into ansible-playbook's own CLI. Reuses the
# exact same TaskExecutor/PluginManager/InventoryParser machinery as
# the playbook engine (connection handling, become, check mode, forks,
# facts) - only the CLI surface and result-display format differ, via
# TaskExecutor's `adhoc: true` flag (see task_executor/executor.cr and
# task_executor/result_display.cr's display_adhoc_result).

require "option_parser"
require "colorize"
require "./src/crystal_play/version"
require "./src/crystal_play/playbook_parser"
require "./src/crystal_play/inventory_parser"
require "./src/crystal_play/task_executor"

pattern = ""
module_name = "command"
module_args = ""
inventory_file = "inventory.ini"
remote_user = nil
become = false
become_user = nil
check_mode = false
forks = 5
limit_hosts = ""
verbose = false

begin
  OptionParser.parse do |parser|
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

    parser.on("-C", "--check", "Don't make changes; predict changes instead (dry-run)") do
      check_mode = true
    end

    parser.on("-f FORKS", "--forks=FORKS", "Run against up to FORKS hosts concurrently (default: 5)") do |fval|
      forks = fval.to_i? || 5
    end

    parser.on("-l SUBSET", "--limit=SUBSET", "Limit to specific hosts") do |subset|
      limit_hosts = subset
    end

    parser.on("-v", "--verbose", "Verbose output") do
      verbose = true
    end

    parser.on("--version", "Show version information") do
      puts CrystalPlay.version_info
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

# Resolve module_name to its AVAILABLE_PLUGINS FQCN, same as a playbook
# task would - the plugin binary is looked up by FQCN, and real ansible
# accepts a bare module name here too (`ansible all -m ping`).
resolved_module = CrystalPlay::PlaybookParser.resolve_module_name(module_name)
unless resolved_module
  puts "Error: Module not found or not supported: #{module_name}".colorize(:red)
  exit 1
end

inventory = nil
begin
  inventory = CrystalPlay::InventoryParser.parse(inventory_file)
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

if hosts.empty?
  puts "Error: No hosts matched: #{pattern}".colorize(:red)
  exit 1
end

if user = remote_user
  hosts.each(&.user=(user))
end

task = CrystalPlay::Task.new(name: "ansible ad-hoc command", module_name: resolved_module)
task.params = CrystalPlay::PlaybookParser.parse_adhoc_params(resolved_module, module_args)
task.become = become
task.become_user = become_user

CrystalPlay::PluginManager.verbose = verbose

# Build the one throwaway Play/Playbook this ad-hoc task needs, purely to
# reuse PluginManager's existing batch-upload pass (pre-uploads the one
# module binary to every matched remote host up front, same as a real
# playbook run) instead of duplicating its per-host connection-dedup
# logic here.
play = CrystalPlay::Play.new(name: "ansible ad-hoc", hosts: pattern)
play.tasks = [task]
play.gather_facts = false
playbook = CrystalPlay::Playbook.new(path: "<ad-hoc>")
playbook.plays = [play]
CrystalPlay::PluginManager.batch_upload_plugins_for_playbook(playbook, inventory, forks)

executor = CrystalPlay::TaskExecutor.new(
  hosts: hosts,
  tasks: [task],
  check_mode: check_mode,
  gather_facts: false,
  inventory: inventory,
  forks: forks,
  adhoc: true
)

executor.run

any_failed = executor.results.values.any? { |host_stats| (host_stats["failed"]? || 0) > 0 }
exit(any_failed ? 2 : 0)
