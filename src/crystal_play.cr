# Crystal Play - Fast Ansible-compatible automation library
# Main library entry point

# Core modules
require "./crystal_play/host"
require "./crystal_play/version"
require "./crystal_play/ssh_config"
require "./crystal_play/ssh_manager"
require "./crystal_play/local_executor"
require "./crystal_play/playbook_parser"
require "./crystal_play/inventory_parser"
require "./crystal_play/variable_substitutor"
require "./crystal_play/facts_gatherer"
require "./crystal_play/base_plugin"
require "./crystal_play/plugin_manager"
require "./crystal_play/task_executor"

module CrystalPlay
  # Main module for Crystal Play automation library
  #
  # Crystal Play is a fast, Ansible-compatible automation tool written in Crystal.
  # It can execute Ansible playbooks with a subset of Ansible's features.
  #
  # ## Usage as a Library
  #
  # ```
  # require "crystal-play"
  #
  # # Parse a playbook
  # playbook = CrystalPlay::PlaybookParser.parse("playbook.yml")
  #
  # # Parse inventory
  # inventory = CrystalPlay::InventoryParser.parse("inventory.ini")
  #
  # # Execute tasks
  # hosts = inventory.get_hosts("webservers")
  # executor = CrystalPlay::TaskExecutor.new(
  #   hosts: hosts,
  #   tasks: playbook.plays.first.tasks,
  #   handlers: playbook.plays.first.handlers
  # )
  # executor.run
  # ```
  #
  # ## Available Components
  #
  # - `PlaybookParser` - Parse YAML playbooks
  # - `InventoryParser` - Parse INI/YAML inventories
  # - `TaskExecutor` - Execute tasks on hosts
  # - `SSHManager` - Manage SSH connections with pooling
  # - `VariableSubstitutor` - Handle Ansible variable substitution
  # - `FactsGatherer` - Gather system facts from hosts
  # - `PluginManager` - Manage and execute plugins
  #
  # See individual class documentation for details.
end
