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
    property? success : Bool
    property modified_params : Hash(String, String)?
    property error_message : String?
    property? changed : Bool

    # Set only by an action plugin that computes the task's ENTIRE result
    # on the controller and needs no module invocation at all (debug:/
    # assert:/fail:/set_fact:/pause: - see their own action-plugin files
    # under action_plugins/). When present, the caller (prepare_batch_step
    # / execute_task_once / the handler path) skips plugin upload/dispatch
    # entirely and uses this JSON as the task's result verbatim (still
    # passed through apply_changed_failed_when, same as any other
    # result) - distinct from modified_params, which still expects a real
    # module (local or remote) to run afterward with the substituted
    # params (template:'s own use).
    property final_result : JSON::Any?

    def initialize(@success : Bool, @modified_params : Hash(String, String)? = nil,
                   @error_message : String? = nil, @changed : Bool = false,
                   @final_result : JSON::Any? = nil)
    end

    # Create success result
    def self.success?(modified_params : Hash(String, String), changed : Bool = false) : ActionResult
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

    # Create a final, controller-computed result - no module ever runs.
    def self.final(result : JSON::Any) : ActionResult
      new(success: true, final_result: result)
    end

    # Shared builder for the flat result hash PluginResult#to_json
    # produces (changed/failed/msg + extra fields at the top level, no
    # nesting) - used by every final-result action plugin
    # (action_plugins/*.cr) so each one only needs to name its own extra
    # fields, not re-derive this shape.
    def self.plugin_result_json(changed : Bool, failed : Bool, msg : String, extra : Hash(String, JSON::Any) = Hash(String, JSON::Any).new) : JSON::Any
      h = Hash(String, JSON::Any).new
      h["changed"] = JSON::Any.new(changed)
      h["failed"] = JSON::Any.new(failed)
      h["msg"] = JSON::Any.new(msg)
      extra.each { |k, v| h[k] = v }
      JSON::Any.new(h)
    end
  end
end
