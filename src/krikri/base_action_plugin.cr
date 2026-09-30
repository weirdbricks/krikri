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

    # Set when the failure was raised by the controller-side ACTION
    # plugin itself (a bare AnsibleActionFail): the [ERROR] block is the
    # plain "Task failed: <msg>" chain with no "Module failed." middle
    # segment and the fatal dump's msg stays un-prefixed, unlike a
    # module-side failure. The executor's action-failure result builders
    # turn this into the result's _ansible_action_level key (see
    # ResultDisplay's own branch).
    property? action_level : Bool

    # The [ERROR] block's own text when it differs from the result's msg.
    # Real's task executor wraps an UNCAUGHT Python exception raised inside
    # an action plugin itself ("Task failed: %s" % to_native(e)), so such a
    # failure's fatal msg carries that prefix while the block still shows
    # the bare message - which is what this carries. A deliberate
    # AnsibleActionFail has no prefix in either place, so it stays nil.
    property? error_detail : String?

    def initialize(@success : Bool, @modified_params : Hash(String, String)? = nil,
                   @error_message : String? = nil, @changed : Bool = false,
                   @final_result : JSON::Any? = nil, @action_level : Bool = false,
                   @error_detail : String? = nil)
    end

    # Create success result
    def self.success?(modified_params : Hash(String, String), changed : Bool = false) : ActionResult
      new(success: true, modified_params: modified_params, changed: changed)
    end

    # Create failure result
    def self.failure(error_message : String) : ActionResult
      new(success: false, error_message: error_message)
    end

    # Create a failure result raised by the ACTION plugin itself (a bare
    # AnsibleActionFail - add_host's "name, host or hostname needs to be
    # provided"): rendered action-level, not module-level (see
    # #action_level).
    def self.action_failure(error_message : String) : ActionResult
      new(success: false, error_message: error_message, action_level: true)
    end

    # Create a failure raised by an UNCAUGHT Python exception inside the
    # action plugin - the codec-stack crash real's template action plugin
    # dies with on a non-string output_encoding ("encode() argument
    # 'encoding' must be str, not _AnsibleTaggedInt") and its
    # unknown-codec LookupError. Real's task executor wraps such an
    # exception itself, so the fatal dump's msg keeps the "Task failed: "
    # prefix while the [ERROR] block shows the bare message (see
    # #error_detail).
    def self.crash_failure(error_message : String) : ActionResult
      new(success: false,
        error_message: "Task failed: #{error_message}",
        action_level: true, error_detail: error_message)
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
    # that: hitting an undefined reference or a non-bool result). Real
    # ansible-core 2.19.11 (live-verified: `assert: that: undef_var == 1`
    # with register:) registers changed=false+failed=true+msg and dumps
    # the fatal line as {"changed": false, "msg": "Task failed: ..."} -
    # the same shape as the when:/ path's when_error_result; an older
    # 2.19 build showed a changed-less registered var, but 2.19.11 is
    # the parity target. An ordinary failing assertion still registers
    # changed: false alongside via plugin_result_json.
    def self.conditional_error_result_json(msg : String) : JSON::Any
      h = Hash(String, JSON::Any).new
      h["changed"] = JSON::Any.new(false)
      h["failed"] = JSON::Any.new(true)
      h["msg"] = JSON::Any.new(msg)
      JSON::Any.new(h)
    end
  end
end
