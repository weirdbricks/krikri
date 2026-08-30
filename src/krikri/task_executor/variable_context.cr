require "json"
require "../host"
require "../playbook_parser"

module Krikri
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
      registered_vars : Hash(String, JSON::Any),
    ) : Hash(String, JSON::Any)
      # Grows through role_defaults + play_vars + host.vars + registered_vars
      # + role_vars + task.vars - routinely 100+ entries by the time
      # build_vars_context (executor.cr) layers facts on top, so the
      # default ~8-bucket start would rehash several times over.
      context = Hash(String, JSON::Any).new(initial_capacity: 256)

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
