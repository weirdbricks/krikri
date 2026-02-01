require "json"

module CrystalPlay
  # EnvironmentFacts - Gathers environment variable facts
  module EnvironmentFacts
    # Gather environment facts
    # Populates: ansible_env
    def self.gather(facts : Hash(String, JSON::Any), execute_callback : Proc(String, String?))
      # ansible_env - environment variables (limited set)
      env_vars = ["PATH", "HOME", "USER", "SHELL", "TERM", "LANG"]
      env = Hash(String, JSON::Any).new
      
      env_vars.each do |var|
        value = execute_callback.call("echo $#{var}")
        env[var] = JSON::Any.new(value.strip) if value && !value.strip.empty?
      end
      
      facts["ansible_env"] = JSON::Any.new(env) unless env.empty?
    end
  end
end
