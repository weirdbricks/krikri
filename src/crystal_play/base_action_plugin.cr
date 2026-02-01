require "json"

module CrystalPlay
  # Base class for Action Plugins
  # Action plugins run on the CONTROLLER (local machine) before the module runs on remote
  # They process inputs, read files, render templates, etc.
  # 
  # Examples of action plugins:
  # - template: Reads template file locally, renders it, sends rendered content to remote
  # - copy: Can read source file locally and send content to remote
  # - fetch: Retrieves files from remote to controller
  
  abstract class ActionPlugin
    property params : Hash(String, String)
    property vars : Hash(String, JSON::Any)
    property host : Host
    
    def initialize(@params : Hash(String, String), @vars : Hash(String, JSON::Any), @host : Host)
    end
    
    # Execute action on controller
    # Returns: modified params to send to remote plugin, or nil if action failed
    abstract def execute : ActionResult
    
    # Check if this plugin should run
    # Some action plugins only run under certain conditions
    def should_run? : Bool
      true
    end
  end
  
  # Result from action plugin execution
  class ActionResult
    property success : Bool
    property modified_params : Hash(String, String)?
    property error_message : String?
    property changed : Bool
    
    def initialize(@success : Bool, @modified_params : Hash(String, String)? = nil, 
                   @error_message : String? = nil, @changed : Bool = false)
    end
    
    # Create success result
    def self.success(modified_params : Hash(String, String), changed : Bool = false) : ActionResult
      new(success: true, modified_params: modified_params, changed: changed)
    end
    
    # Create failure result
    def self.failure(error_message : String) : ActionResult
      new(success: false, error_message: error_message)
    end
    
    # Create pass-through result (no modifications)
    def self.pass_through : ActionResult
      new(success: true, modified_params: nil)
    end
  end
end
