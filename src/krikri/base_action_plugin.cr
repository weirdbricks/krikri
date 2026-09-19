require "json"

module Krikri
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

    # The task's OWN host (the play's hosts: entry) when the task carries
    # delegate_to: - nil when it doesn't (and always nil-equal to @host
    # then, since resolve_delegate_host falls back to the original host).
    # Only synchronize reads it: real Ansible runs its rsync on the
    # delegate but qualifies the OTHER rsync end from the ORIGINAL host's
    # connection details, which the delegate-resolved @host alone can't
    # reconstruct.
    property task_host : Host?

    # The run's ONE shared Inventory instance (nil only in contexts that
    # never had one) - only meaningful for plugins that mutate controller-
    # side state across plays (add_host:). Passed through execute_action's
    # own optional parameter; most action plugins ignore it entirely.
    getter inventory : Inventory?

    def initialize(@params : Hash(String, String), @vars : Hash(String, JSON::Any), @host : Host, @inventory : Inventory? = nil, @task_host : Host? = nil)
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
      # Unlike a module's own wire result (PluginResult#to_json), these
      # controller-computed results are already in real Ansible's
      # post-normalization shape - the executor's failed/changed-if-absent
      # pass has no second look at them - so failed/changed are carried
      # unconditionally, exactly like a registered var sees. msg follows
      # the module rule: only present when the action actually passed one
      # (real set_fact/add_host results carry no msg at all).
      h["failed"] = JSON::Any.new(failed)
      h["msg"] = JSON::Any.new(msg) unless msg.empty?
      extra.each { |k, v| h[k] = v }
      JSON::Any.new(h)
    end

    # The result shape for a CONDITIONAL-EVALUATION failure (assert:'s
    # that: hitting an undefined reference or a non-bool result) - the
    # conditional failed before any module ran, and real Ansible's
    # registered var for this shape carries ONLY failed+msg, with no
    # `changed` key at all (live-verified against ansible-core 2.19:
    # `assert: that: undef_var == 1` with register: gives
    # keys=['failed', 'msg']; a later task reading `<reg>.changed` sees
    # it as undefined and fails its own templating, while an ordinary
    # failing assertion still registers changed: false alongside).
    # plugin_result_json can't express the missing key, so this builds
    # the hash directly. The when:/ path's identical shape lives in
    # Executor's when_error_result/swallow_when_error.
    def self.conditional_error_result_json(msg : String) : JSON::Any
      h = Hash(String, JSON::Any).new
      h["failed"] = JSON::Any.new(true)
      h["msg"] = JSON::Any.new(msg)
      JSON::Any.new(h)
    end
  end
end
