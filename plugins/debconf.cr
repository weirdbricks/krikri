#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Debconf plugin - pre-seeds/reads a package's debconf database
  # entries. Compatible with Ansible's ansible.builtin.debconf module.
  #
  # Shells to the real `debconf-set-selections`/`debconf-show`/
  # `debconf-get-selections` binaries, mirroring Ansible's own
  # module exactly (it does the same - no python-apt/libdebconf binding
  # either). apt-only; these binaries don't exist on RHEL-family hosts.
  #
  # required_together: Ansible's module declares
  # `required_together=(['question', 'vtype', 'value'],)` - passing any
  # one of question:/vtype:/value: (aliases selection:/setting: and
  # answer:) without the other two fails with AnsibleModule's own
  # validation message, "parameters are required together: question,
  # vtype, value" (the Ansible module's exact
  # wording).
  #
  # Not implemented: `vtype: password`'s own idempotency read-back
  # (`get_password_value`, parsing `debconf-get-selections`'s raw tab-
  # separated dump for a password-typed question) - Ansible's own
  # docs recommend `no_log: true` for password questions precisely
  # because the value is sensitive, and this is a narrow, rarely-hit
  # shape; a `vtype: password` task here always re-applies (`changed:
  # true` every run) rather than silently under-reporting drift.
  class DebconfPlugin < BasePlugin
    # ansible.builtin.debconf's `type: bool` options, in the real argument-spec
    # declaration order (ansible-doc -j ansible.builtin.debconf). Validated at
    # module setup by BasePlugin#validate_bool_params! - see its block
    # comment for the real-Ansible semantics and message wording.
    protected def bool_params : Array(String)
      %w[unseen]
    end

    def execute : PluginResult
      validate_bool_params!
      pkg = @params["name"]? || @params["pkg"]?
      return missing_param("name") unless pkg

      question = debconf_question
      vtype = @params["vtype"]?
      value = debconf_value
      unseen = true?(@params["unseen"]?)

      # Ansible's module declares
      # `required_together=(['question', 'vtype', 'value'],)` - if any
      # one of the three is given, ALL three must be, or AnsibleModule's
      # own validation fails with (validation.py's exact wording):
      # "parameters are required together: question, vtype, value".
      # Previously only the question-side half was checked here, so
      # `vtype:`/`value:` alone (or question+value without vtype)
      # silently "succeeded" as "No question given, nothing to set"
      # instead of failing like Ansible.
      if error = validate_question_triple(question, vtype, value)
        return error
      end

      if question.nil? || vtype.nil? || value.nil?
        return PluginResult.new(changed: false, failed: false, msg: "No question given, nothing to set")
      end

      apply_selection(pkg, question, vtype, value, unseen)
    end

    # Ansible's own flow from here on: read the package's current
    # selections, refuse a null value, compare, and only then - outside
    # check mode - build and write the debconf-set-selections line, which
    # is where a non-string `value:` literal kills the module (see
    # #selection_type_failure), so an unchanged value and a --check run
    # both report changed without ever getting there.
    private def apply_selection(pkg : String, question : String, vtype : String, value : String, unseen : Bool) : PluginResult
      prev = get_selections(pkg)

      # Ansible's `if vtype is None or value is None` guard (debconf.py:210)
      # sits AFTER get_selections (a debconf-show failure is reported
      # first) and BEFORE the comparison: a literal `value:` with no
      # value - or a template that natively resolved to Python None - is
      # None there, not an empty string.
      return missing_vtype_or_value if value_param_null?

      changed = value_differs?(prev, question, vtype, value)

      if changed && !true?(@params["_ansible_check_mode"]?)
        if error = selection_type_failure(vtype)
          return error
        end

        result = set_selection(pkg, question, vtype, value, unseen)
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: result[:stderr])
        end
      end

      # Real debconf.py exit shapes (live-verified against Ansible 2.19.11
      # via registered {{ r | to_json }} dumps in the podman container):
      # a changed selection (check mode included) exits with
      # changed,msg,current,previous,diff; an already-set rerun with
      # changed,msg,current. krikri doesn't emit current/previous/diff
      # (pre-existing content gap); the pin only fixes the relative
      # order.
      PluginResult.new(changed: changed, failed: false, msg: changed ? "Value set" : "Value already set",
        key_order: changed ? ["changed", "msg", "current", "previous", "diff"] : ["changed", "msg", "current"])
    end

    # question:/selection:/setting: are documented aliases of each other
    private def debconf_question : String?
      @params["question"]? || @params["selection"]? || @params["setting"]?
    end

    private def validate_question_triple(question : String?, vtype : String?, value : String?) : PluginResult?
      given_count = [question, vtype, value].count { |v| v }
      if 0 < given_count < 3
        return PluginResult.new(changed: false, failed: true,
          msg: "parameters are required together: question, vtype, value")
      end

      # Ansible's argument_spec restricts vtype to a choices list
      # (debconf.py); AnsibleModule's choice check (parameters.py's
      # exact wording) fires for a full triple with a bad vtype before
      # any debconf-show/debconf-set-selections call - previously a bad
      # vtype sailed through and the task reported changed: true.
      vtype_choices = ["boolean", "error", "multiselect", "note", "password", "seen", "select", "string", "text", "title"]
      if vtype && !vtype_choices.includes?(vtype)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of vtype must be one of: #{vtype_choices.join(", ")}, got: #{vtype}")
      end
      nil
    end

    # value:/answer: are documented aliases of each other
    private def debconf_value : String?
      @params["value"]? || @params["answer"]?
    end

    # The wire key value:/answer: actually arrived under - the native-type
    # marker rides on the key the task used, not on the alias.
    private def value_param_key : String?
      return "value" if @params.has_key?("value")
      return "answer" if @params.has_key?("answer")
      nil
    end

    # Was value:/answer: explicitly null (a literal `value:`, or a
    # template that natively resolved to None)? BasePlugin demotes both
    # to "" and records the null (see NONE_SENTINEL).
    private def value_param_null? : Bool
      key = value_param_key
      !key.nil? && explicit_null_param?(key)
    end

    # debconf.py:210's fail_json, verbatim.
    private def missing_vtype_or_value : PluginResult
      PluginResult.new(changed: false, failed: true,
        msg: "when supplying a question you must supply a valid vtype and value")
    end

    # The failure Ansible's set_selection (debconf.py:179) dies with for a
    # `value:` that is not a Python string: it builds the line with
    # `' '.join([pkg, question, vtype, value])`, and the uncaught
    # TypeError ends the module ("Task failed: Module failed: sequence
    # item 3: expected str instance, int found" - live-verified vs
    # 2.19.11 for int/bool/float). name/question/vtype cannot reach it:
    # their `type: str` spec converts an int literal to its text, and
    # only `value:` (`type: raw`) keeps its own type.
    #
    # `vtype: boolean` is the one carve-out - Ansible runs the value through
    # `to_text(value).lower()` for its comparison (debconf.py:214), which
    # makes ANY type a string before the join is ever reached, so an int
    # value there seeds "76" like real.
    #
    # A `value:` LIST is a different join in real: under `vtype:
    # multiselect` the list itself is joined, so a non-string member fails
    # there instead (see #multiselect_join_failure). A list under any
    # other vtype would crash like a scalar, but that shape cannot reach a
    # plugin at all - the strings-only param wire comma-joins a list of
    # plain strings into text indistinguishable from one string - so only
    # the members the parser marked (see #marked_list_members) are
    # visible here.
    private def selection_type_failure(vtype : String) : PluginResult?
      return nil if vtype == "boolean"
      key = value_param_key
      return nil unless key

      if (members = marked_list_members(key)) && vtype == "multiselect"
        return multiselect_join_failure(members)
      end
      return nil unless (native = non_string_param(key))

      join_crash(3, Krikri.python_join_type_name(native))
    end

    # Ansible's `", ".join(value)` for a multiselect list whose members are
    # not all strings (debconf.py:239-243), which real catches and
    # reports as its own fail_json instead of crashing. It sorts the list
    # first, so a homogeneous non-string list always names its FIRST
    # element. A list mixing strings and non-strings never gets there -
    # Ansible's sorted() raises its own "'<' not supported between
    # instances of ..." TypeError first, which is deliberately not
    # mirrored (the pair Python names there depends on list order).
    private def multiselect_join_failure(members : Array(JSON::Any)) : PluginResult?
      natives = members.reject { |member| member.raw.is_a?(String) }
      return nil if natives.empty?
      return nil unless natives.all? { |member| member.raw.class == natives.first.raw.class }

      PluginResult.new(changed: false, failed: true,
        msg: "Invalid value provided for 'multiselect': sequence item 0: " \
             "expected str instance, #{Krikri.python_join_type_name(natives.first)} found")
    end

    # The native members of a parser comma-joined list value, read from
    # the RAW wire - BasePlugin's demotion has already turned the member
    # markers into plain text by the time a plugin sees @params
    # (set_fact/xml read @config["params"] the same way for the same
    # reason). nil when the value is not a marked list.
    private def marked_list_members(key : String) : Array(JSON::Any)?
      raw = @config["params"]?.try(&.as_h?).try { |params| params[key]?.try(&.as_s?) }
      Krikri.non_string_list_members(raw)
    end

    # The uncaught-module-crash shape Ansible's own task executor renders:
    # the "Task failed: Module failed: " brief in the fatal msg, the bare
    # exception text in the [ERROR] block (see BasePlugin's
    # _ansible_error_detail bookkeeping, and mount's own os.makedirs('')).
    private def join_crash(index : Int32, type_name : String) : PluginResult
      detail = "sequence item #{index}: expected str instance, #{type_name} found"
      PluginResult.new(changed: false, failed: true,
        msg: "Task failed: Module failed: #{detail}", _ansible_error_detail: detail)
    end

    # Does the stored selection differ from the requested value?
    # Boolean questions are compared case-insensitively (debconf stores
    # booleans lowercased; Ansible's module normalizes the same way)
    private def value_differs?(prev : Hash(String, String), question : String, vtype : String, value : String) : Bool
      compare_value = vtype == "boolean" ? value.downcase : value
      existing = prev[question]?
      existing = existing.try { |e| vtype == "boolean" ? e.downcase : e }

      existing != compare_value
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end

    # `debconf-show <pkg>` prints one `[*] question: value` line per
    # known question (`*` marks it "seen") - strip the leading `*`/
    # whitespace off the key, same as Ansible's own `get_selections`.
    private def get_selections(pkg : String) : Hash(String, String)
      result = remote_exec("debconf-show #{shell_single_quote(pkg)} 2>/dev/null")
      selections = Hash(String, String).new
      result[:stdout].each_line do |line|
        key, sep, val = line.partition(':')
        next if sep.empty?
        selections[key.strip('*').strip] = val.strip
      end
      selections
    end

    private def set_selection(pkg : String, question : String, vtype : String, value : String, unseen : Bool) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      flag = unseen ? "-u " : ""
      data = "#{pkg} #{question} #{vtype} #{value}"
      remote_exec("echo #{shell_single_quote(data)} | debconf-set-selections #{flag}".strip)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::DebconfPlugin.new(config)
plugin.run
