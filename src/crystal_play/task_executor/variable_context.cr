require "json"
require "../host"
require "../playbook_parser"

module CrystalPlay
  # VariableContext - Builds variable contexts from multiple sources
  # Combines play vars, host vars, task vars, and registered vars
  module VariableContext
    # Build variable context combining all variable sources
    # Priority (highest to lowest): task vars > role vars > registered vars
    # > host vars > play vars > role defaults
    def self.build(
      play_vars : Hash(String, JSON::Any), # CHANGED: Was Hash(String, String)
      host : Host,
      task : Task,
      registered_vars : Hash(String, JSON::Any)
    ) : Hash(String, JSON::Any)
      context = Hash(String, JSON::Any).new

      # Role defaults (lowest priority - only ever fill gaps a higher tier
      # doesn't already cover)
      if defaults = task.role_defaults
        defaults.each { |key, value| context[key] = value }
      end

      # Add play-level variables
      play_vars.each do |key, value|
        context[key] = value # CHANGED: Just assign directly, it's already JSON::Any
      end

      # Add host variables
      host.vars.each do |key, value|
        context[key] = value
      end

      # Add registered variables for this host
      registered_vars.each do |key, value|
        context[key] = value
      end

      # Role vars (role's vars/main.yml + the role invocation's own vars:)
      if role_vars = task.role_vars
        role_vars.each { |key, value| context[key] = value }
      end

      # Add task-level variables (highest priority)
      task.vars.each do |key, value|
        context[key] = value
      end

      context
    end
  end
end
