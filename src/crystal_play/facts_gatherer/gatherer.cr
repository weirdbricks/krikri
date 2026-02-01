require "json"
require "../ssh_manager"
require "../host"
require "./hostname_facts"
require "./os_facts"
require "./network_facts"
require "./hardware_facts"
require "./python_facts"
require "./user_facts"
require "./environment_facts"
require "./date_time_facts"

module CrystalPlay
  # FactsGatherer - Gathers system facts about remote hosts (Ansible-compatible)
  # Populates ansible_* variables automatically
  class FactsGatherer
    @ssh_manager : SSHManager
    @host : Host
    
    def initialize(@ssh_manager : SSHManager, @host : Host)
    end
    
    # Gather all facts and return as Hash
    def gather : Hash(String, JSON::Any)
      facts = Hash(String, JSON::Any).new
      
      # Create callback for executing commands
      # This allows modules to execute commands without knowing about SSH
      execute_callback = ->(cmd : String) : String? {
        execute_command(cmd)
      }
      
      # Gather facts from each module
      HostnameFacts.gather(facts, execute_callback)
      OSFacts.gather(facts, execute_callback)
      NetworkFacts.gather(facts, execute_callback)
      HardwareFacts.gather(facts, execute_callback)
      PythonFacts.gather(facts, execute_callback)
      UserFacts.gather(facts, execute_callback)
      EnvironmentFacts.gather(facts, execute_callback)
      DateTimeFacts.gather(facts, execute_callback)
      
      facts
    end
    
    # Execute command on remote host
    private def execute_command(cmd : String) : String?
      begin
        result = @ssh_manager.execute(@host, cmd)
        return result["stdout"].as_s if result["rc"].as_i == 0
        nil
      rescue
        nil
      end
    end
  end
end
