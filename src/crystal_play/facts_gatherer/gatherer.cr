require "json"
require "../ssh_manager"
require "../local_executor"
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
    @host : Host
    
    def initialize(@host : Host)
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
        # Get connection details
        connection_host = @host.vars["ansible_host"]?.try(&.as_s?) || @host.name
        user = @host.user || "root"
        port = @host.port
        
        # Check if local connection
        if @host.vars["ansible_connection"]?.try(&.as_s?) == "local" || @host.name == "localhost"
          # Execute locally
          result = LocalExecutor.exec(cmd)
          return result[:stdout] if result[:exit_code] == 0
        else
          # Execute via SSH
          result = SSHManager.exec(connection_host, user, cmd, port)
          return result[:stdout] if result[:exit_code] == 0
        end
        
        nil
      rescue
        nil
      end
    end
  end
end
