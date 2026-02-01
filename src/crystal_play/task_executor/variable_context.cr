require "json"
require "../host"
require "../playbook_parser"

module CrystalPlay
  # VariableContext - Builds variable contexts from multiple sources
  # Combines play vars, host vars, task vars, and registered vars
  module VariableContext
    # Build variable context combining all variable sources
    # Priority (highest to lowest): task vars > registered vars > host vars > play vars
    def self.build(
      play_vars : Hash(String, String),
      host : Host,
      task : Task,
      registered_vars : Hash(String, JSON::Any)
    ) : Hash(String, JSON::Any)
      context = Hash(String, JSON::Any).new
      
      # Add play-level variables (lowest priority)
      play_vars.each do |key, value|
        context[key] = JSON::Any.new(value)
      end
      
      # Add host variables
      host.vars.each do |key, value|
        context[key] = value
      end
      
      # Add registered variables for this host
      registered_vars.each do |key, value|
        context[key] = value
      end
      
      # Add task-level variables (highest priority)
      task.vars.each do |key, value|
        context[key] = value
      end
      
      context
    end
  end
end
