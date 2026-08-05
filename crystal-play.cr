#!/usr/bin/env crystal

# Crystal Play - Fast Ansible-compatible automation tool
# Main CLI entry point

require "option_parser"
require "colorize"
require "./src/crystal_play/version"
require "./src/crystal_play/playbook_parser"
require "./src/crystal_play/inventory_parser"
require "./src/crystal_play/task_executor"
require "./src/crystal_play/vault"
require "./src/crystal_play/vault_cli"

# `crystal-ansible vault <subcommand> ...` is a completely separate CLI
# surface from running a playbook - dispatch to it before the main
# OptionParser even runs.
if ARGV[0]? == "vault"
  CrystalPlay::VaultCli.run(ARGV[1..])
  exit
end

# `crystal-ansible __async_run <module> <config_path> <status_path>` is an
# internal-only entry point (not a user-facing subcommand): TaskExecutor's
# async:/poll: support spawns this as a detached background process to run
# a single module and write its result to the job's status file, so the
# job outlives the poll loop (or the whole playbook run) rather than being
# tied to a Fiber in the parent process. See
# TaskExecutor#execute_async/AsyncJobs.
if ARGV[0]? == "__async_run"
  module_name = ARGV[1]
  config_path = ARGV[2]
  status_path = ARGV[3]

  config_json = JSON.parse(File.read(config_path))
  local_host = CrystalPlay::Host.new("localhost")
  result = CrystalPlay::PluginManager.execute_plugin(module_name, config_json, local_host, {} of String => JSON::Any)

  result_hash = JSON.parse(result.to_json).as_h
  result_hash["finished"] = JSON::Any.new(1_i64)

  tmp_path = "#{status_path}.tmp"
  File.write(tmp_path, JSON::Any.new(result_hash).to_json)
  File.rename(tmp_path, status_path)
  File.delete(config_path) rescue nil
  exit
end

# Parse command line arguments
playbook_file = ""
inventory_file = "inventory.ini"
check_mode = false
diff_mode = false
batching_enabled = true
verbose = false
limit_hosts = ""
tags = [] of String
vault_password_file = nil
ask_vault_pass = false

begin
  OptionParser.parse do |parser|
    parser.banner = "Usage: crystal-ansible [options] playbook.yml"

    parser.on("-i INVENTORY", "--inventory=INVENTORY", "Specify inventory file") do |inv|
      inventory_file = inv
    end

    parser.on("-c", "--check", "Don't make changes; predict changes instead (dry-run)") do
      check_mode = true
    end

    parser.on("-d", "--diff", "Show file differences when changing files") do
      diff_mode = true
    end

    parser.on("--no-batching", "Disable batching consecutive independent tasks into fewer SSH round trips (on by default since 0.9.63)") do
      batching_enabled = false
    end

    parser.on("-v", "--verbose", "Verbose output") do
      verbose = true
    end

    parser.on("-l SUBSET", "--limit=SUBSET", "Limit to specific hosts") do |subset|
      limit_hosts = subset
    end

    parser.on("-t TAGS", "--tags=TAGS", "Only run tasks with these tags") do |t|
      tags = t.split(",")
    end

    parser.on("--vault-password-file=FILE", "Vault password file") do |file|
      vault_password_file = file
    end

    parser.on("--ask-vault-pass", "Prompt for the vault password") do
      ask_vault_pass = true
    end

    parser.on("--version", "Show version information") do
      puts CrystalPlay.version_info
      exit
    end

    parser.on("-h", "--help", "Show this help") do
      puts parser
      puts ""
      puts "Examples:"
      puts "  crystal-ansible playbook.yml"
      puts "  crystal-ansible --check --diff playbook.yml"
      puts "  crystal-ansible --no-batching playbook.yml"
      puts "  crystal-ansible -i inventory.ini playbook.yml"
      puts "  crystal-ansible --tags deploy playbook.yml"
      puts "  crystal-ansible --vault-password-file pass.txt playbook.yml"
      puts ""
      puts "Vault:"
      puts "  crystal-ansible vault encrypt|decrypt|view|encrypt_string|rekey ..."
      exit
    end

    parser.unknown_args do |args|
      if args.size == 1
        playbook_file = args[0]
      else
        puts "Error: Please specify exactly one playbook file"
        puts parser
        exit 1
      end
    end
  end
rescue ex : OptionParser::InvalidOption
  puts "Error: #{ex.message}".colorize(:red)
  puts ""
  puts "Run 'crystal-ansible --help' for usage information"
  exit 1
rescue ex : Exception
  puts "Error: #{ex.message}".colorize(:red)
  exit 1
end

# Validate args
if playbook_file.empty?
  puts "Error: Playbook file is required"
  puts "Usage: crystal-ansible [options] playbook.yml"
  puts "Try 'crystal-ansible --help' for more information"
  exit 1
end

unless File.exists?(playbook_file)
  puts "Error: Playbook file not found: #{playbook_file}".colorize(:red)
  exit 1
end

if password_file = vault_password_file
  CrystalPlay::Vault.password = File.read(password_file).strip
elsif ask_vault_pass
  CrystalPlay::Vault.password = CrystalPlay::VaultCli.prompt_password
end

# Display banner
puts ""
puts CrystalPlay.banner.colorize(:cyan).bold
puts "=" * 70
puts "Playbook: #{playbook_file}".colorize(:white)
if check_mode
  puts "Mode: CHECK (dry-run)".colorize(:yellow).bold
end
if diff_mode
  puts "Diff: ENABLED".colorize(:green)
end
unless batching_enabled
  puts "Batching: DISABLED".colorize(:yellow)
end
if tags.any?
  puts "Tags: #{tags.join(", ")}".colorize(:cyan)
end
puts "=" * 70
puts ""

# Parse playbook
playbook = nil
begin
  playbook = CrystalPlay::PlaybookParser.parse(playbook_file)

  if verbose
    stats = CrystalPlay::PlaybookParser.stats(playbook)
    puts "Playbook Statistics:".colorize(:green).bold
    puts "  Plays: #{stats["plays"]}".colorize(:white)
    puts "  Tasks: #{stats["tasks"]}".colorize(:white)
    puts "  Handlers: #{stats["handlers"]}".colorize(:white)
    puts "  Modules used: #{stats["modules_used"]}".colorize(:white)
    puts ""
  end

  # Show warnings
  warnings = CrystalPlay::PlaybookParser.validate(playbook)
  if warnings.any?
    puts "Warnings:".colorize(:yellow).bold
    warnings.each do |warning|
      puts "  ⚠️  #{warning}".colorize(:yellow)
    end
    puts ""
  end
rescue ex
  puts "Error parsing playbook:".colorize(:red).bold
  puts "  #{ex.message}".colorize(:red)
  exit 1
end

# Parse inventory
inventory = nil
begin
  inventory = CrystalPlay::InventoryParser.parse(inventory_file)

  if verbose
    stats = CrystalPlay::InventoryParser.stats(inventory)
    puts "Inventory Statistics:".colorize(:green).bold
    puts "  Hosts: #{stats["hosts"]}".colorize(:white)
    puts "  Groups: #{stats["groups"]}".colorize(:white)
    puts "  Variables: #{stats["vars"]}".colorize(:white)
    puts ""
  end

  # Show inventory warnings
  inv_warnings = CrystalPlay::InventoryParser.validate(inventory)
  if inv_warnings.any?
    puts "Inventory Warnings:".colorize(:yellow).bold
    inv_warnings.each do |warning|
      puts "  ⚠️  #{warning}".colorize(:yellow)
    end
    puts ""
  end
rescue ex
  puts "Error loading inventory:".colorize(:red).bold
  puts "  #{ex.message}".colorize(:red)
  puts ""
  puts "Please check that your inventory file exists and is properly formatted.".colorize(:yellow)
  puts "Use -i flag to specify a different inventory file.".colorize(:yellow)
  exit 1
end

# At this point inventory is guaranteed to be set
inventory = inventory.not_nil!

if verbose
  puts "Available Hosts:".colorize(:cyan).bold
  inventory.hosts.each do |name, host|
    # Show ansible_host (IP) if set, otherwise show hostname
    connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
    puts "  - #{host.user}@#{connection_host}:#{host.port}".colorize(:white)
  end
  puts ""
end

# Set verbose mode for plugin manager
CrystalPlay::PluginManager.verbose = verbose

# Batch upload plugins to all remote hosts before execution
# This is much more efficient than uploading during task execution
if playbook && inventory
  CrystalPlay::PluginManager.batch_upload_plugins_for_playbook(playbook, inventory)
end

# Execute playbook
all_hosts = [] of CrystalPlay::Host
combined_results = Hash(String, Hash(String, Int32)).new
# Hosts that hard-failed (a task failed without ignore_errors:) in an
# earlier play this run - excluded from every *remaining* play's host
# list too, matching real Ansible's own behavior (a failure removes a
# host from the rest of the whole run, not just the play it happened
# in). TaskExecutor's own halted_hosts is scoped to one play/one
# instance (crystal-play.cr constructs a fresh one per play); this set
# carries that forward across the per-play loop below.
permanently_failed_hosts = Set(String).new

playbook.plays.each_with_index do |play, play_index|
  puts ""
  puts "PLAY [#{play.name}]".colorize(:magenta).bold
  puts "=" * 70
  puts ""

  # Get hosts for this play from inventory, excluding any host that
  # already hard-failed in an earlier play this run.
  matched_hosts = inventory.get_hosts(play.hosts.to_s)
  hosts = matched_hosts.reject { |host| permanently_failed_hosts.includes?(host.name) }

  if matched_hosts.empty?
    puts "Skipping play - no hosts match pattern: #{play.hosts}".colorize(:yellow)
    next
  elsif hosts.empty?
    puts "Skipping play - all matching hosts already failed in an earlier play".colorize(:yellow)
    next
  end

  # Track hosts for recap
  all_hosts.concat(hosts)

  if verbose
    # Show connection hosts (IPs) if different from inventory names
    host_display = hosts.map do |host|
      connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
      connection_host
    end.join(", ")
    puts "Hosts in play: #{host_display}".colorize(:cyan)
    puts ""
  end

  # Get tasks for this play
  tasks_to_run = play.tasks

  # Filter by tags if specified
  if tags.any?
    tasks_to_run = tasks_to_run.select do |task|
      task.tags.any? { |tag| tags.includes?(tag) }
    end

    if tasks_to_run.empty?
      puts "Skipping play - no tasks match tags: #{tags.join(", ")}".colorize(:yellow)
      next
    end
  end

  if tasks_to_run.empty?
    puts "Skipping play - no tasks defined".colorize(:yellow)
    next
  end

  # Create task executor with handlers and play vars
  executor = CrystalPlay::TaskExecutor.new(
    hosts: hosts,
    tasks: tasks_to_run,
    handlers: play.handlers,
    check_mode: check_mode,
    diff_mode: diff_mode,
    play_vars: play.vars,
    gather_facts: play.gather_facts,
    inventory: inventory,
    batching_enabled: batching_enabled
  )

  # Run tasks
  executor.run

  # Carry any host that hard-failed in this play forward - excluded from
  # every remaining play too, not just the rest of this one.
  permanently_failed_hosts.concat(executor.halted_hosts)

  # Merge this play's per-host stats into the running total (a host can
  # appear in more than one play).
  executor.results.each do |host_name, host_stats|
    if existing = combined_results[host_name]?
      host_stats.each { |key, value| existing[key] = (existing[key]? || 0) + value }
    else
      combined_results[host_name] = host_stats.dup
    end
  end
end

# Summary
puts ""
puts "=" * 70
puts "PLAY RECAP".colorize(:cyan).bold
puts "=" * 70

CrystalPlay::ResultDisplay.show_recap(all_hosts.uniq { |h| h.name }, combined_results)

puts ""

any_failed = combined_results.values.any? { |host_stats| (host_stats["failed"]? || 0) > 0 }

if check_mode
  puts "NOTE: Running in check mode - no changes were made".colorize(:yellow).bold
  puts ""
end

if any_failed
  puts "✗ Playbook execution completed with failures".colorize(:red).bold
  puts ""
  exit 2
end

puts "✓ Playbook execution complete".colorize(:green).bold
puts ""
