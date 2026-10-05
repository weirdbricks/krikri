require "json"
require "digest/sha1"
require "big"
require "./param_sentinels"

# Data-driven module argument validation, matching ansible-core's
# AnsibleModule argument-spec checks word-for-word.
#
# The spec table (data/argspecs.json) is GENERATED from the installed
# ansible-core + collections by scripts/gen_argspecs.py: it captures each
# module's own AnsibleModule(argument_spec=...) call (options, aliases,
# types, required, choices, defaults, mutually_exclusive/required_together/
# required_one_of/required_if/required_by) plus live-probed facts the spec
# itself cannot tell you (which module name Ansible prints in
# "Unsupported parameters for (...) module" when an action plugin delegates
# - template runs copy, shell runs command - and which action-only
# directives validate at all).
#
# Check order mirrors ansible-core's ArgumentSpecValidator.validate() +
# AnsibleModule.__init__ error selection: only the FIRST error in that
# order is ever surfaced (errors[0]):
#   mutually_exclusive -> required -> types -> choices -> required_together
#   -> required_one_of -> required_if -> required_by -> unsupported params
# (unsupported-params is collected during the walk but appended to the
# error list LAST, so a missing-required error beats a typo'd parameter -
# live-verified: docker_container with a typo and no name reports
# "missing required arguments: name", not the typo).
module Krikri
  module ArgspecValidator
    extend self

    # Kept out of validation: engine-internal wire keys Ansible's module
    # never sees (real strips the _ansible_* namespace generically; the
    # others are krikri's own bookkeeping keys).
    # Package-manager modules `package: use:` can name (core + common community).
    PACKAGE_MANAGERS = %w[apt apt_rpm dnf dnf5 yum yum4 dnf4 zypper pacman apk homebrew pkgng openbsd_pkg
      pkgin portage xbps slackpkg swupd urpmi opkg pkg5 rpm_ostree_pkg macports bsd_pkg]

    INTERNAL_KEYS = [
      "_module_name", "_first_gather", "_environment", "_verbosity",
      "_rendered_from_template", "_content_checksum",
      "__original_src_basename",
      "__cleanup_after_copy", "__cleanup_after_copy_dir",
    ]

    # The assemble-only options Ansible's action plugin consumes itself and
    # never forwards to the copy module it delegates to when
    # remote_src: is falsy (assemble.py action's clean-up loop).
    ASSEMBLE_ACTION_CONSUMED = ["remote_src", "regexp", "delimiter", "ignore_hidden", "decrypt"]

    # The assemble action's controller-side branch: remote_src is PRESENT
    # and boolean(remote_src, strict=False) is not True - falsy spellings,
    # invalid spellings ('timjjr'), explicit None and non-1 native numbers
    # all land here (see Krikri.lenient_boolean_true? for the exact
    # predicate, live-verified vs 2.19.11). An ABSENT remote_src takes the
    # module branch (the action's default is the string 'yes').
    private def assemble_action_local_path?(params : Hash(String, String)) : Bool
      return false unless params.has_key?("remote_src")
      !Krikri.lenient_boolean_true?(params["remote_src"]?)
    end

    # convert_bool.py's BOOLEANS as Ansible's error message reprs them (a
    # Python set iteration - order differs between module processes, so
    # this fixed order is one Ansible emits; only the membership is stable).
    BOOLEANS_REPR = %w['off' 1 'true' 'y' 0 'false' 'on' 'no' '1' 'yes' '0' 'n' 'f' 't']
    REAL_TRUE     = %w[y yes on 1 true t]
    REAL_FALSE    = %w[n no off 0 false f]

    # The param wire is strings-only; an explicit YAML null rides as
    # NONE_SENTINEL and {{ omit }} removes the key entirely upstream.

    class Failure
      getter msg : String
      # Action-only directives (debug, assert, fail, ...) fail with a
      # chain that has no "Module failed." middle segment.
      getter? action_level : Bool
      # debug's fatal dump carries ONLY msg (Ansible's callback shape for
      # its own action result) - its failure result omits "changed".
      getter? omit_changed : Bool

      def initialize(@msg, @action_level = false, @omit_changed = false)
      end
    end

    @@table : Hash(String, JSON::Any)? = nil

    # Params the sweep environment's collections mark removed_in_version:
    # passing one deprecates at module bootstrap (the general
    # "Param 'x' is deprecated. ... removed from collection 'C' version N"
    # wording) - but only when the module's run actually returns
    # (normally or via fail_json): see validate's deprecation gate.
    # Extended as the corpus surfaces more of them.
    private REMOVED_PARAM_DEPRECATIONS = {
      "community.crypto.openssl_pkcs12" => {"maciter_size" => "4.0.0"},
    }

    private def table : Hash(String, JSON::Any)
      @@table ||= JSON.parse({{ read_file("#{__DIR__}/../../data/argspecs.json") }}).as_h
    end

    @@option_order : Hash(String, Array(String))? = nil

    # Each module's option names in Ansible's argument_spec DECLARATION order
    # (data/argspecs.json preserves it; Crystal's JSON object decode does
    # not). Ansible's validation walks the spec dict in declaration order, so
    # the first failing option - not the hash-decoded order - decides which
    # type/choices error wins. Re-read through a pull parser because the
    # table itself was decoded order-less above.
    private def option_order_table : Hash(String, Array(String))
      @@option_order ||= begin
        order = Hash(String, Array(String)).new
        pull = JSON::PullParser.new({{ read_file("#{__DIR__}/../../data/argspecs.json") }})
        pull.read_object do |module_name|
          names = [] of String
          pull.read_object do |key|
            if key == "options"
              pull.read_object do |option_name|
                names << option_name
                pull.skip
              end
            else
              pull.skip
            end
          end
          order[module_name] = names
        end
        order
      end
    end

    # The options map as (name, spec) pairs in declaration order; names
    # missing from the order list (defensive) keep their relative order
    # at the end.
    private def ordered_option_pairs(options : Hash(String, JSON::Any), order : Array(String)?) : Array(Tuple(String, JSON::Any))
      pairs = options.to_a
      return pairs unless order
      pairs.sort_by! { |(name, _)| order.index(name) || order.size }
      pairs
    end

    # Whether this msg on this module is an argspec-validation failure we
    # emitted (used by ResultDisplay to pick the right error-block chain
    # shape - template's own file-not-found chain must not swallow these).
    def failure_kind?(module_name : String, msg : String) : Symbol?
      return :action if action_level_fixed_msg?(module_name, msg)
      entry = table[module_name]?
      return nil unless entry
      return nil if entry["no_validate"]?
      return nil unless validation_msg?(msg)
      entry["action_level"]?.try(&.as_bool?) ? :action : :module
    end

    # The action-plugin-level failures whose text is not a spec-check
    # message (Ansible's action plugins check these before the module's own
    # AnsibleModule init runs), keyed by module; every one of these
    # modules has a table entry, so checking them before the entry
    # lookup changes nothing.
    private def action_level_fixed_msg?(module_name : String, msg : String) : Bool
      case module_name
      when "ansible.builtin.template", "ansible.builtin.assemble"
        msg == "src and dest are required"
      when "ansible.builtin.package"
        msg.starts_with?("Could not find a matching action for the")
      when "ansible.builtin.unarchive"
        {"parameters are mutually exclusive: ('copy', 'remote_src')", "src (or content) and dest are required"}.includes?(msg)
      else
        false
      end
    end

    private def validation_msg?(msg : String) : Bool
      msg.starts_with?("Unsupported parameters for (") ||
        msg.starts_with?("missing required arguments:") ||
        msg.starts_with?("Invalid options for ") ||
        msg.starts_with?("value of ") || msg.starts_with?("argument '") ||
        msg.starts_with?("parameters are ") ||
        msg.starts_with?("one of the following is required:") ||
        msg.starts_with?("missing parameter(s) required by ")
    end

    # Validates one module invocation's params against the real spec.
    # action_name is the module spelling AS WRITTEN in the task (real
    # prints that in the Unsupported-parameters message, except for the
    # delegating action plugins with a fixed name); module_name is the
    # resolved FQCN the table is keyed by. Returns nil when nothing fails
    # (or the module has no spec to check against).
    def validate(
      action_name : String,
      module_name : String,
      params : Hash(String, String),
      vars_context : Hash(String, JSON::Any),
    ) : Failure?
      entry = table[module_name]?
      return nil unless entry
      return nil if entry["no_validate"]?

      outcome = validate_spec_entry(action_name, module_name, entry, params, vars_context)

      # A removed_in_version-marked param the task passed deprecates at
      # the Ansible module's own bootstrap (_handle_params). The warning
      # travels in the module RESULT, so whether it reaches stderr
      # mirrors how the module run ends: a module-level spec failure IS
      # Ansible's AnsibleModule fail_json exit (unsupported parameters,
      # mutually exclusive, ...) and shows the deprecation; an
      # action-plugin-level failure, a skip or an unreachable never run
      # the module, so they print nothing; and an uncaught module
      # exception drops it - Ansible's crash wrapper builds its result
      # without the collected deprecations (all live-verified vs 2.19.11
      # with openssl_pkcs12's maciter_size). Module-level failures emit
      # right here (the module has "run" - bootstrap and all - and
      # fail_json'd); a passing validation defers to the module's actual
      # outcome, which only the result's display point knows:
      # ResultDisplay.consume_pending_module_deprecations.
      removed = removed_deprecation_texts(module_name, params)
      if failure = outcome.failure
        if !failure.action_level? && !removed.empty?
          removed.each { |text| Krikri::ResultDisplay.emit_core_deprecation(text) }
        end
        return failure
      end
      unless outcome.deferred || removed.empty?
        Krikri::ResultDisplay.stash_pending_module_deprecations(module_name, removed)
      end
      nil
    end

    private record SpecOutcome, failure : Failure?, deferred : Bool

    # The text of the removed_in_version deprecations the task's params
    # trigger, in table order (empty when none).
    private def removed_deprecation_texts(module_name : String, params : Hash(String, String)) : Array(String)
      return [] of String unless removed = REMOVED_PARAM_DEPRECATIONS[module_name]?
      collection = module_name.split(".")[0...-1].join(".")
      removed.compact_map do |param, version|
        next nil unless params.has_key?(param)
        "Param '#{param}' is deprecated. See the module docs for more information. " \
        "This feature will be removed from collection '#{collection}' version #{version}."
      end
    end

    # The spec-check tail of validate (everything but the removed-param
    # gate): failure is the first spec error in Ansible's check order, nil
    # when the params pass. deferred is Ansible's "the action plugin settled
    # the outcome itself" exits, where the module may not run at all - a
    # passing-but-deferred validation must not pre-arm the removed-param
    # deprecation.
    private def validate_spec_entry(
      action_name : String,
      module_name : String,
      entry : JSON::Any,
      params : Hash(String, String),
      vars_context : Hash(String, JSON::Any),
    ) : SpecOutcome
      if failure = action_plugin_required_params(module_name, params)
        return SpecOutcome.new(failure, false)
      end

      # Custom callable spec types (assert's str_or_list_of_str) reject a
      # natively-typed scalar where the demoted wire text would pass -
      # capture the markers (alias-resolved to the canonical option name)
      # BEFORE the strip below hides them.
      non_string_natives = collect_non_string_natives(entry, params)
      non_string_lists = collect_non_string_lists(entry, params)

      params = prepare_module_params(module_name, params, entry)

      outcome = action_plugin_preflight(module_name, params, entry, non_string_natives, non_string_lists, vars_context)
      return SpecOutcome.new(outcome.failure, false) if outcome.failure
      return SpecOutcome.new(nil, true) if outcome.defer?

      if failure = action_plugin_option_failures(module_name, params, non_string_natives, non_string_lists)
        return SpecOutcome.new(failure, false)
      end

      # package's action plugin consumes `use:` itself (it names the
      # backend module to delegate to, defaulting to the ansible_pkg_mgr
      # fact) and deletes it from the args it forwards (package.py:89-91),
      # so the backend module's spec never sees it - `use` is not in
      # apt/dnf/yum's argument_spec and a `package: {use: auto}` task
      # must not fail the backend's Unsupported-parameters check
      # (live-verified vs 2.19.11: brucellino.docker's
      # `package: {use: auto}` tasks run through apt fine). The use:
      # backend-name check above already ran on the unstripped params.
      if module_name == "ansible.builtin.package"
        params = params.reject { |key, _| key == "use" }
      end

      # unarchive's action plugin checks that dest is an existing directory
      # (AnsibleActionFail) before the module ever validates its arguments;
      # a dest that is not a directory here defers to the plugin's own failure.
      return SpecOutcome.new(nil, false) if defers_to_unarchive_action?(module_name, params)

      print_name, entry, spec_owner = resolve_entry(action_name, module_name, entry, vars_context)
      return SpecOutcome.new(nil, false) unless entry

      SpecOutcome.new(validate_spec_entry_tail(action_name, print_name, entry, spec_owner, params, non_string_natives, non_string_lists), false)
    end

    # What the action-plugin checks that run BEFORE module argument
    # validation decided for a task: a `failure` to report, or `defer`
    # when the action plugin settled the outcome itself (a delegated
    # copy-spec result, or a check the module must not run past) and
    # there is nothing further for validate to do.
    private class ActionOutcome
      getter failure : Failure?
      getter? defer : Bool

      def initialize(@failure : Failure?, @defer : Bool = false)
      end
    end

    # copy's action plugin (copy.py:428-430) and assemble's
    # (assemble.py:103-104) both check required params BEFORE the module
    # validates anything - each with its own two messages (a failed
    # result, "Action failed." chain) - and their checks are PYTHON
    # TRUTHINESS checks, not key-presence checks: a non-string YAML
    # literal that is falsy (false, 0, 0.0 - the parser marks those, see
    # NON_STRING_PARAM_PREFIX) or an empty string counts as "not
    # provided" exactly like a missing key (live-verified vs 2.19.11:
    # `dest: false`/`dest: 0`/`dest: ""` all fail "dest is required",
    # `src: 0` with no content fails "src (or content) is required",
    # while `src: 0` WITH content runs the content path - the falsy src
    # is simply ignored). assemble's own check is a None check instead:
    # an explicitly null param counts as absent, an empty string does
    # not.
    private def action_plugin_required_params(module_name : String, params : Hash(String, String)) : Failure?
      if module_name == "ansible.builtin.copy"
        unless params.has_key?("content") || Krikri.python_param_truthy?(params["src"]?)
          return Failure.new("src (or content) is required", true)
        end
        return Failure.new("dest is required", true) unless params.has_key?("dest") && Krikri.python_param_truthy?(params["dest"]?)
      end

      if module_name == "ansible.builtin.assemble" &&
         (!provided_param?(params, "src") || !provided_param?(params, "dest"))
        return Failure.new("src and dest are required", true)
      end

      nil
    end

    # The parser's non-string YAML LIST literals (a comma-joined wire with
    # NON_STRING_MEMBER_PREFIX-marked members, e.g. `status_code: [1.5]`),
    # captured under the canonical option name BEFORE the demotion strip -
    # the per-element type checks (elements=int) need the members' native
    # types, which the stripped wire text has lost.
    private def collect_non_string_lists(entry : JSON::Any, params : Hash(String, String)) : Hash(String, JSON::Any)
      alias_lookup = alias_map(entry["options"]?.try(&.as_h?) || Hash(String, JSON::Any).new)
      lists = {} of String => JSON::Any
      params.each do |key, value|
        next if INTERNAL_KEYS.includes?(key)
        if members = Krikri.non_string_list_members(value)
          lists[alias_lookup[key]? || key] = JSON::Any.new(members)
        end
      end
      lists
    end

    # The natively-typed params captured under their canonical (alias
    # resolved) option name, before the markers below are stripped.
    private def collect_non_string_natives(entry : JSON::Any, params : Hash(String, String)) : Hash(String, JSON::Any)
      alias_lookup = alias_map(entry["options"]?.try(&.as_h?) || Hash(String, JSON::Any).new)
      non_string_natives = {} of String => JSON::Any
      params.each do |key, value|
        next if INTERNAL_KEYS.includes?(key)
        if native = Krikri.non_string_scalar(value)
          non_string_natives[alias_lookup[key]? || key] = native
        end
      end
      non_string_natives
    end

    # The params as the action plugin leaves them for the module: debug's
    # marked list members re-encoded as the array they are, copy's
    # action-only `content`/`decrypt` keys dropped, `follow` pre-coerced
    # to the boolean copy's action plugin hands the module, and the
    # parser's non-string-literal markers (NON_STRING_PARAM_PREFIX)
    # demoted back to the plain string form every spec check has always
    # seen (so a marked `follow: true` validates like the "true" text it
    # always was).
    private def prepare_module_params(module_name : String, params : Hash(String, String), entry : JSON::Any) : Hash(String, String)
      # debug's spec (data/argspecs.json) types two of its three options as
      # SCALARS, and a YAML list rides a comma-joined wire that no scalar
      # check could tell from a plain string - unless one of its members was
      # a non-string scalar, which the parser marks per member. Those marked
      # values are re-encoded as the JSON array they really are (before the
      # strip below drops the markers), so debug's type errors report Ansible's
      # list - and repr it with the same members. A list of strings only
      # stays indistinguishable: nothing about its wire is marked.
      if module_name == "ansible.builtin.debug"
        params = params.map { |key, value| {key, marked_list_as_json(value)} }.to_h
      end

      # copy's ACTION plugin builds the copy module's args with
      # _create_remote_copy_args, which drops the two action-only keys
      # `content` and `decrypt` (copy.py:47-49) - `decrypt` is not in the
      # copy spec at all, so a template or copy task that sets it is never
      # rejected for it (live-verified vs 2.19.11: `decrypt: notabool`
      # plus a typo'd option reports the typo, not decrypt).
      if module_name == "ansible.builtin.template" || module_name == "ansible.builtin.copy"
        params = params.reject { |key, _| key == "decrypt" }
      end

      # copy's and template's ACTION plugins read `follow` themselves,
      # through boolean(value, strict=False), and hand the copy MODULE the
      # coerced boolean (copy.py:328-335 and :519-520; template.py does the
      # same before it even delegates) - so the copy module never sees a
      # non-boolean `follow`: an invalid spelling is simply False and can
      # never fail the task, not even when a typo'd option is present
      # alongside it (live-verified vs 2.19.11: template with
      # `follow: hcsjhk` plus `gropu` fails with copy's
      # Unsupported-parameters error, and a wrong-typed `backup:` alongside
      # a bad `follow` reports the backup bool error). copy's own action
      # plugin only takes that path when remote_src is FALSY under the very
      # same boolean(strict=False) (copy.py:422) - a truthy one hands the
      # raw args to the module, where a bad `follow` DOES fail the spec
      # (live-verified vs 2.19.11).
      if module_name == "ansible.builtin.template" ||
         (module_name == "ansible.builtin.copy" && !Krikri.lenient_boolean_true?(params["remote_src"]?))
        if follow = params["follow"]?
          params = params.merge({"follow" => (Krikri.lenient_boolean_true?(follow) ? "true" : "false")})
        end
      end

      Krikri.strip_non_string_param_markers(params)
    end

    # assemble's controller-side action plugin, which either swallows the
    # task (its isdir() check fails before any module argument validation
    # runs) or hands the placement to the COPY module instead:
    #
    # A remote_src the action plugin treats as falsy
    # (boolean(strict=False) - every non-BOOLEANS_TRUE value, invalid
    # spellings included) and a src that is NOT a directory: Ansible's
    # action plugin assembles the fragments on the controller and
    # delegates the file placement to the COPY module (assemble.py
    # action: _execute_module('ansible.legacy.copy')) after stripping
    # the assemble-only options (remote_src/regexp/delimiter/
    # ignore_hidden/decrypt) - so the module-level argument validation
    # that rejects anything is COPY's spec, not assemble's: the message
    # names (ansible.legacy.copy) and lists copy's own supported
    # parameters (live-verified vs 2.19.11: a typo'd
    # ignoer_hidden/mode_bogus fails through copy's spec, not
    # assemble's). The branch predicate is NOT boolean(remote_src,
    # strict=False), not a falsy-spelling list: an INVALID spelling
    # ('timjjr') or an explicit None returns False from boolean()
    # without raising, so it delegates exactly like 'false' does - and
    # the copy module never sees remote_src at all, which is why Ansible's
    # fatal for a typo'd gorup + non-bool 'timjjr' remote_src is copy's
    # Unsupported-parameters error, not assemble's remote_src
    # bool-conversion error (the assemble module, and its strict
    # remote_src conversion with it, never runs).
    private def action_plugin_preflight(
      module_name : String,
      params : Hash(String, String),
      entry : JSON::Any,
      non_string_natives : Hash(String, JSON::Any),
      non_string_lists : Hash(String, JSON::Any),
      vars_context : Hash(String, JSON::Any),
    ) : ActionOutcome
      if module_name == "ansible.builtin.assemble" && assemble_action_local_path?(params)
        return ActionOutcome.new(nil, true) unless (src = params["src"]?) && Dir.exists?(src)
        if copy_entry = table["ansible.builtin.copy"]?
          delegated = params.reject { |key, _| ASSEMBLE_ACTION_CONSUMED.includes?(key) }
          return ActionOutcome.new(validate_spec_entry("ansible.builtin.copy", "ansible.builtin.copy", delegated,
            copy_entry, non_string_natives, non_string_lists, vars_context), true)
        end
      end

      if failure = action_plugin_option_failures(module_name, params, non_string_natives, non_string_lists)
        return ActionOutcome.new(failure)
      end

      ActionOutcome.new(nil)
    end

    # The option checks template's, package's and unarchive's own action
    # plugins run before the module validates anything, each in its own
    # order.
    private def action_plugin_option_failures(module_name : String, params : Hash(String, String), non_string_natives : Hash(String, JSON::Any), non_string_lists : Hash(String, JSON::Any)) : Failure?
      case module_name
      when "ansible.builtin.template"
        return template_action_failure(params)
      when "ansible.builtin.package"
        return package_action_failure(params)
      when "ansible.builtin.unarchive"
        return unarchive_arg_failure(params)
      when "ansible.builtin.uri"
        return uri_action_failure(params, non_string_natives, non_string_lists)
      end
      nil
    end

    # uri's controller-side action plugin, in its
    # own order, both before the module validates anything - which is why
    # they are action-level failures here and not module-side checks in
    # plugins/uri.cr:
    #
    #   * `src:` without a truthy remote_src: is resolved on the
    #     CONTROLLER (_find_needle) and staged to the target; a file that
    #     isn't there fails with _find_needle's own message, which is why
    #     that one - and only that one - carries a "Task failed: " prefix
    #     INSIDE msg (live-verified vs 2.19.11: the fatal dump shows
    #     {"msg": "Task failed: Could not find or access '...' on the
    #     Ansible Controller.\nIf you are using a module and expect the
    #     file to exist on the remote, see the remote_src option"}, while
    #     the multipart guard below has none). Being an action-level
    #     failure also decides its place against the module's own
    #     mutually_exclusive check: `src:` (missing) + `body:` reports the
    #     controller-side message, the same pair with an existing src
    #     reports "parameters are mutually exclusive: body|src".
    #   * body_format: form-multipart with a body that is not a mapping.
    #     Only reachable when src is absent/falsy (the action's own
    #     if/elif) - a truthy remote_src: returns from the action plugin
    #     before either branch runs, and the module's own copy of the
    #     check then produces the different, module-worded message (see
    #     plugins/uri.cr). Ansible sees the TEMPLATED args here, so every
    #     non-bool scalar/container reports its _AnsibleTagged* subclass
    #     name while a bool stays plain `bool` (live-verified vs
    #     2.19.11 across NoneType/bool/str/int/float/list).
    #
    # The staging itself stays unimplemented for a genuinely remote target
    # (and so does its transfer-failure message, which embeds the
    # controller's own tmp path); for ansible_connection=local - the
    # overwhelmingly common uri+src case - controller and target are the
    # same filesystem and the existence check is the whole story.
    private def uri_action_failure(params : Hash(String, String), non_string_natives : Hash(String, JSON::Any), non_string_lists : Hash(String, JSON::Any)) : Failure?
      # A truthy remote_src: short-circuits the whole controller-side
      # branch (Ansible's action plugin returns the module result directly),
      # so neither check below can fire.
      return nil if Krikri.lenient_boolean_true?(params["remote_src"]?)

      src = params["src"]?
      if src && Krikri.python_param_truthy?(src)
        unless File.exists?(src)
          return Failure.new("Task failed: Could not find or access '#{src}' on the Ansible Controller.\n" \
                             "If you are using a module and expect the file to exist on the remote, see the remote_src option", true)
        end
      elsif params["body_format"]? == "form-multipart"
        if type_name = uri_multipart_body_type_name(params, non_string_natives, non_string_lists)
          return Failure.new("body must be mapping, cannot be type #{type_name}", true)
        end
      end
      nil
    end

    # Python class name for a uri body: that is not a mapping, spelled the
    # way Ansible's own action-plugin guard spells it. A parser-marked
    # non-string YAML literal or list literal (NON_STRING_PARAM_PREFIX /
    # the member markers) keeps its native type; every other value
    # arrives as text, where a value that parses as JSON is a container
    # (list), and text that does not parse is a plain string.
    private def uri_multipart_body_type_name(params : Hash(String, String), non_string_natives : Hash(String, JSON::Any), non_string_lists : Hash(String, JSON::Any)) : String?
      return "_AnsibleTaggedList" if non_string_lists.has_key?("body")

      raw = params["body"]?
      return "NoneType" if raw.nil? || raw == Krikri::NONE_SENTINEL

      marked = uri_marked_body_type_name(non_string_natives)
      return marked if marked

      # JSON.parse(...).raw, NOT the JSON::Any itself: `case json when
      # Bool` against a JSON::Any subject never matches (the case tests
      # the wrapper's type), which silently turned a JSON-typed body into
      # "no failure at all".
      parsed = begin
        JSON.parse(raw).raw
      rescue
        nil
      end
      return "_AnsibleTaggedStr" if parsed.nil?

      # A JSON object is a Mapping, the one shape that passes the check;
      # no `else` arm, because that is exactly the nil this returns.
      case parsed
      when Bool    then "bool"
      when Int64   then "_AnsibleTaggedInt"
      when Float64 then "_AnsibleTaggedFloat"
      when String  then "_AnsibleTaggedStr"
      when Array   then "_AnsibleTaggedList"
      end
    end

    # The class name of a body: the parser marked as a non-string YAML
    # literal, or nil when it was an ordinary string/container value.
    private def uri_marked_body_type_name(non_string_natives : Hash(String, JSON::Any)) : String?
      native = non_string_natives["body"]?
      return nil unless native
      case native.raw
      when Bool    then "bool"
      when Int64   then "_AnsibleTaggedInt"
      when Float64 then "_AnsibleTaggedFloat"
      when Array   then "_AnsibleTaggedList"
      when Nil     then "NoneType"
      end
    end

    # template's controller-side action plugin checks src/dest presence
    # BEFORE any module argument validation (AnsibleActionFail). The
    # check only ever sees the ORIGINAL task params: once the action has
    # run, src has been consumed into the rendered content (the copy
    # module gets a real src tempfile), so a post-action run must fall
    # through to the spec checks - that is where real surfaces the copy
    # module's rejection of the template-only leftovers the action did
    # not consume (a typo'd output_encoding etc.).
    #
    # Its own order: the string-typed option coercion, then the state
    # check, then src/dest, then newline_sequence - all before the copy
    # module ever sees the args. `state` is a None check, so a `state:`
    # with no value passes (live-verified vs 2.19.11: `state: present`
    # plus a typo'd option reports the state error, and copy's
    # unsupported-parameter error never gets to run).
    private def template_action_failure(params : Hash(String, String)) : Failure?
      if !params.has_key?("content") && (!params.has_key?("src") || !params.has_key?("dest"))
        return Failure.new("src and dest are required", true)
      end
      if provided_param?(params, "state")
        return Failure.new("'state' cannot be specified on a template", true)
      end
      nil
    end

    # package's action plugin: an unknown `use:` manager fails before the
    # delegated module ever validates anything.
    private def package_action_failure(params : Hash(String, String)) : Failure?
      if (use = params["use"]?) && use != "auto" && !PACKAGE_MANAGERS.includes?(use)
        return Failure.new(%(Could not find a matching action for the "#{use}" package manager.), true)
      end
      nil
    end

    # unarchive's action plugin, in order: copy+remote_src conflict, then
    # src/dest required - all before the module validates anything.
    private def unarchive_arg_failure(params : Hash(String, String)) : Failure?
      if params.has_key?("copy") && params.has_key?("remote_src")
        return Failure.new("parameters are mutually exclusive: ('copy', 'remote_src')", true)
      end
      unless params.has_key?("src") && params.has_key?("dest")
        return Failure.new("src (or content) and dest are required", true)
      end
      nil
    end

    # Whether unarchive's own dest-is-a-directory check (below its
    # arg-shape checks) settles the task instead of the module.
    private def defers_to_unarchive_action?(module_name : String, params : Hash(String, String)) : Bool
      return false unless module_name == "ansible.builtin.unarchive"
      dest = params["dest"]?
      !dest.nil? && !Dir.exists?(dest)
    end

    # The spec-check tail shared by the direct path and the assemble ->
    # copy delegation above: fact-delegated/print-name resolution, then
    # the check chain and the Unsupported-parameters failure.
    private def validate_spec_entry(
      action_name : String,
      module_name : String,
      params : Hash(String, String),
      entry : JSON::Any,
      non_string_natives : Hash(String, JSON::Any),
      non_string_lists : Hash(String, JSON::Any),
      vars_context : Hash(String, JSON::Any),
    ) : Failure?
      print_name, entry, spec_owner = resolve_entry(action_name, module_name, entry, vars_context)
      return nil unless entry

      validate_spec_entry_tail(action_name, print_name, entry, spec_owner, params, non_string_natives, non_string_lists)
    end

    private def validate_spec_entry_tail(
      action_name : String,
      print_name : String,
      entry : JSON::Any,
      spec_owner : String,
      params : Hash(String, String),
      non_string_natives : Hash(String, JSON::Any),
      non_string_lists : Hash(String, JSON::Any),
    ) : Failure?
      if supported = entry["supported"]?.try(&.as_a?)
        return virtual_supported_failure(action_name, print_name, entry, params, supported)
      end
      if entry["unsupported_kind"]?.try(&.as_s?) == "invalid_options"
        valid = entry["valid"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
        return virtual_invalid_options_failure(print_name, params, valid)
      end

      options = entry["options"]?.try(&.as_h?) || Hash(String, JSON::Any).new
      provided, unsupported = collect_provided(params, options, consumed_keys(entry))

      defaults = default_values(options)
      failure_msg = run_spec_checks(spec_owner, entry, options, provided, defaults, unsupported, non_string_natives, non_string_lists)
      if failure_msg
        return Failure.new(failure_msg, entry["action_level"]?.try(&.as_bool?) || false,
          omit_changed: result_keys_msg_only?(entry))
      end

      if unsupported.empty?
        nil
      else
        Failure.new(unsupported_params_message(print_name, unsupported, options),
          entry["action_level"]?.try(&.as_bool?) || false,
          omit_changed: result_keys_msg_only?(entry))
      end
    end

    # An action-only directive whose real callback result carries ONLY msg
    # (debug): its failure dump is {"msg": ...} with no changed key at
    # all, unlike a module failure's {"changed": false, "msg": ...} - the
    # task executor drops the key when this is set.
    private def result_keys_msg_only?(entry : JSON::Any) : Bool
      entry["result_keys"]?.try(&.as_a?) == ["msg"]
    end

    # The JSON array a comma-joined list wire really is, when at least one
    # of its members carried the parser's non-string-scalar member marker;
    # the value unchanged otherwise. See the debug branch in #validate.
    private def marked_list_as_json(value : String) : String
      return value unless value.includes?(Krikri::NON_STRING_MEMBER_PREFIX)
      members = [] of JSON::Any
      value.split(',').each do |part|
        stripped = part.strip
        members << (Krikri.non_string_member_scalar(stripped) || JSON::Any.new(stripped))
      end
      JSON::Any.new(members).to_json
    end

    # `invocation.module_args` of a module result: every spec option under
    # its canonical name, the provided (type-converted) value or its default
    # (null when none). nil for a module without a spec or an action-plugin
    # module whose result carries no invocation.
    def invocation_args(module_name : String, params : Hash(String, String)) : Hash(String, JSON::Any)?
      entry = table[module_name]?
      return nil unless entry
      return nil if entry["no_validate"]? || entry["supported"]? || entry["unsupported_kind"]?
      params = Krikri.strip_non_string_param_markers(params)
      options = entry["options"]?.try(&.as_h?) || return nil
      return nil if options.empty?
      provided, _unsupported = collect_provided(params, options, consumed_keys(entry))
      result = Hash(String, JSON::Any).new
      options.each do |name, spec|
        if (raw = provided[name]?) && raw == Krikri::NONE_SENTINEL
          result[name] = JSON::Any.new(nil)
        elsif raw = provided[name]?
          result[name] = convert_invocation_value(raw, spec["type"]?.try(&.as_s?) || "str")
        else
          result[name] = spec["default"]? || JSON::Any.new(nil)
        end
      end
      result
    end

    private def convert_invocation_value(raw : String, type : String) : JSON::Any
      case type
      when "bool"
        convert_invocation_bool(raw)
      when "int"
        raw.to_i64?.try { |v| JSON::Any.new(v) } || JSON::Any.new(raw)
      when "float"
        raw.to_f64?.try { |v| JSON::Any.new(v) } || JSON::Any.new(raw)
      when "list"
        convert_invocation_list(raw)
      when "dict"
        (JSON.parse(raw) rescue JSON::Any.new(raw))
      when "path"
        JSON::Any.new(raw.starts_with?("~") ? File.expand_path(raw) : raw)
      else
        JSON::Any.new(raw)
      end
    end

    # A bool-typed wire value: Ansible's own TRUE/FALSE words convert, and
    # anything else rides through as the plain string (Ansible's
    # boolean(value, strict=False) leaves an unrecognized spelling
    # alone rather than failing here).
    private def convert_invocation_bool(raw : String) : JSON::Any
      down = raw.downcase
      return JSON::Any.new(true) if REAL_TRUE.includes?(down)
      return JSON::Any.new(false) if REAL_FALSE.includes?(down)
      JSON::Any.new(raw)
    end

    # A list-typed wire value: the JSON form first, then the
    # comma-joined one the demoter produces for a YAML list.
    private def convert_invocation_list(raw : String) : JSON::Any
      parsed = (JSON.parse(raw) rescue nil)
      return parsed if parsed && parsed.as_a?
      JSON::Any.new(raw.split(",").map { |part| JSON::Any.new(part.strip) })
    end

    # Wire params, alias-normalized: canonical name -> raw wire string.
    # Ansible's _handle_aliases runs before every check, so an alias
    # spelling counts exactly like its canonical name; anything that
    # maps to neither lands in the unsupported list (reported LAST).
    private def collect_provided(
      params : Hash(String, String),
      options : Hash(String, JSON::Any),
      consumed : Array(String),
    ) : {Hash(String, String), Array(String)}
      provided = Hash(String, String).new
      unsupported = [] of String
      aliases = alias_map(options)
      params.each do |key, value|
        next if key.starts_with?("_ansible_") || INTERNAL_KEYS.includes?(key)
        next if consumed.includes?(key)
        canonical = aliases[key]? || (options.has_key?(key) ? key : nil)
        if canonical
          provided[canonical] = value
        else
          unsupported << key
        end
      end
      {provided, unsupported}
    end

    private def consumed_keys(entry : JSON::Any) : Array(String)
      entry["consumed_by_action"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
    end

    # Ansible's action-plugin presence checks are None checks
    # (self._task.args.get('src', None)): the key must exist AND hold a
    # non-None value - an explicitly null param counts as absent, an
    # empty string does not.
    private def provided_param?(params : Hash(String, String), key : String) : Bool
      value = params[key]?
      !value.nil? && value != Krikri::NONE_SENTINEL
    end

    # The spec-check chain in Ansible's ArgumentSpecValidator order;
    # only the FIRST failing check's message is ever surfaced (Ansible's
    # AnsibleModule fails on errors[0]).
    private def run_spec_checks(
      spec_owner : String,
      entry : JSON::Any,
      options : Hash(String, JSON::Any),
      provided : Hash(String, String),
      defaults : Hash(String, JSON::Any),
      unsupported : Array(String),
      non_string_natives : Hash(String, JSON::Any),
      non_string_lists : Hash(String, JSON::Any),
    ) : String?
      # Ansible's ArgumentSpecValidator.validate runs its no_log value walk
      # (_list_no_log_values) immediately after alias resolution - before
      # mutually_exclusive, required, or any type conversion. A string
      # element of a dict-typed option THAT HAS suboptions (or a dict
      # option itself) which cannot be parsed as a dict raises
      # check_type_dict's bare TypeError there, and its text becomes
      # errors[0] verbatim - the "Elements value for option ..." wrapping
      # only happens later, for options WITHOUT suboptions (which the
      # walk never descends into). Specs regenerated with nested
      # "options"/"elements" keys make this check data-driven.
      order = option_order_table[spec_owner]?
      if msg = check_no_log_walk(options, provided, order)
        return msg
      end
      if msg = check_mutually_exclusive(entry, provided)
        return msg
      end
      if msg = check_required(options, provided, defaults)
        return msg
      end
      if msg = check_types(options, provided, non_string_natives, non_string_lists, order)
        return msg
      end
      if msg = check_choices(options, provided, order)
        return msg
      end
      if msg = check_required_together(entry, provided, defaults)
        return msg
      end
      if msg = check_required_one_of(entry, provided, defaults)
        return msg
      end
      if msg = check_required_if(entry, provided, defaults)
        return msg
      end
      if msg = check_required_by(entry, provided, defaults)
        return msg
      end
      nil
    end

    # Resolves fact-delegated specs (service -> systemd, package -> apt)
    # and computes the module name Ansible would print for this invocation.
    # Returns {print_name, effective_entry} - effective_entry nil means
    # the spec target cannot be determined (no host fact), so validation
    # is skipped rather than guessed.
    # Computes the module name Ansible would print for this invocation, the
    # effective entry, and the FQCN whose declaration-ordered options the
    # spec checks walk (a fact-delegated target owns the order, not the
    # action spelling).
    private def resolve_entry(action_name : String, module_name : String, entry : JSON::Any, vars_context : Hash(String, JSON::Any)) : {String, JSON::Any?, String}
      if delegated = resolve_fact_delegate(action_name, module_name, entry, vars_context)
        return delegated
      end

      print_name = action_name
      if print_spec = entry["print"]?
        if fixed = print_spec["fixed"]?.try(&.as_s?)
          print_name = fixed
        elsif override = print_spec.as_h[action_name]?
          print_name = override.as_s
        end
      end
      {print_name, entry, module_name}
    end

    # The fact-delegating half of resolve_entry, or nil for a spec that
    # isn't fact-delegated at all.
    private def resolve_fact_delegate(action_name : String, module_name : String, entry : JSON::Any, vars_context : Hash(String, JSON::Any)) : {String, JSON::Any?, String}?
      fact_delegate = entry["fact_delegate"]?
      return nil unless fact_delegate
      fact = fact_delegate["fact"].as_s
      fact_value = delegating_fact(fact, vars_context)
      target = fact_delegate["map"].as_h[fact_value]?.try(&.as_s)
      if target && (target_entry = table[target]?)
        return {"ansible.legacy.#{target.split(".").last}", target_entry, target}
      end
      return {action_name, nil, module_name} unless fact == "ansible_service_mgr"

      {"ansible.legacy.#{module_name.split(".").last}", entry, module_name}
    end

    # Facts not gathered: Ansible's action plugin runs setup for just the
    # delegating fact on demand. service: systemd only when PID 1 is
    # systemd, any other manager runs the service module ITSELF against
    # its own spec. package: the host's package manager (apt on Debian).
    # An unknown fact stays empty, which no map entry resolves.
    private def delegating_fact(fact : String, vars_context : Hash(String, JSON::Any)) : String
      fact_value = vars_context[fact]?.try(&.as_s?) || ""
      return fact_value unless fact_value.empty?
      case fact
      when "ansible_service_mgr"
        File.read("/proc/1/comm").strip == "systemd" ? "systemd" : "service" rescue "service"
      when "ansible_pkg_mgr"
        File.exists?("/usr/bin/apt-get") ? "apt" : ""
      else
        ""
      end
    end

    private def alias_map(options : Hash(String, JSON::Any)) : Hash(String, String)
      map = Hash(String, String).new
      options.each do |name, spec|
        if aliases = spec["aliases"]?.try(&.as_a?)
          aliases.each do |a|
            map[a.as_s] = name
          end
        end
      end
      map
    end

    private def default_values(options : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      defaults = Hash(String, JSON::Any).new
      options.each do |name, spec|
        if d = spec["default"]?
          defaults[name] = d
        end
      end
      defaults
    end

    # Ansible's check_mutually_exclusive runs BEFORE defaults are applied:
    # only actually-provided params count (aliases resolve to their
    # canonical name for the count).
    private def check_mutually_exclusive(entry : JSON::Any, provided : Hash(String, String)) : String?
      groups = entry["mutually_exclusive"]?.try(&.as_a?) || return nil
      failing = [] of String
      groups.each do |group|
        names = group.as_a.map(&.as_s)
        count = names.count { |name| provided.has_key?(name) }
        failing << names.join("|") if count > 1
      end
      failing.empty? ? nil : "parameters are mutually exclusive: #{failing.join(", ")}"
    end

    # Real applies non-null defaults before the required check, so a
    # defaulted option is never missing; required+null-default stays
    # missing (the None default does not stand in for a provided value).
    private def check_required(options : Hash(String, JSON::Any), provided : Hash(String, String), defaults : Hash(String, JSON::Any)) : String?
      missing = [] of String
      options.each do |name, spec|
        next unless spec["required"]?.try(&.as_bool?)
        next if provided.has_key?(name)
        next if defaults[name]? && !defaults[name].raw.nil?
        missing << name
      end
      missing.empty? ? nil : "missing required arguments: #{missing.sort.join(", ")}"
    end

    private def check_types(options : Hash(String, JSON::Any), provided : Hash(String, String),
                            non_string_natives : Hash(String, JSON::Any),
                            non_string_lists : Hash(String, JSON::Any), order : Array(String)?) : String?
      ordered_option_pairs(options, order).each do |name, spec|
        raw = provided[name]?
        next unless raw
        wanted = spec["type"]?.try(&.as_s?) || "str"
        error = type_error(name, wanted, raw, spec, non_string_natives[name]?)
        return error if error
        # The option's own type converted cleanly: a list typed option
        # with an elements= constraint converts each element in the same
        # walk (Ansible's check_type_list runs the element checker inline),
        # so uri's status_code element failure is part of the types pass
        # and beats any later option's type error and every choices check
        # (live-verified vs 2.19.11).
        error = elements_type_error(name, spec, raw, non_string_natives[name]?, non_string_lists[name]?)
        return error if error
      end
      nil
    end

    # Ansible's custom callable type (assert action's str_or_list_of_str): a
    # string passes, a list whose every element is a string passes, and
    # anything else raises TypeError("a string or list of strings is
    # required"), which _validate_argument_types wraps as "argument 'x' is
    # of type <native type> and we were unable to convert to
    # str_or_list_of_str: ...". The wire sees a marked non-string scalar
    # (int/float/bool) where Ansible sees the native Python value; a plain
    # string wire value IS Ansible's str case, and a JSON-encoded list is
    # Ansible's list case.
    private def str_or_list_type_error(name : String, raw : String, native : JSON::Any?) : String?
      tail = "a string or list of strings is required"
      if list = (JSON.parse(raw) rescue nil).try(&.as_a?)
        return nil if list.all?(&.as_s?)
        return "argument '#{name}' is of type list and we were unable to convert to str_or_list_of_str: #{tail}"
      end
      kind = case native.try(&.raw)
             when Int64, Int32 then "int"
             when Float64      then "float"
             when Bool         then "bool"
             else                   "str"
             end
      return nil if kind == "str"
      "argument '#{name}' is of type #{kind} and we were unable to convert to str_or_list_of_str: #{tail}"
    end

    # Ansible's _list_no_log_values walk: for every provided option that is
    # type=dict, or type=list with elements=dict AND its own options=
    # sub-spec, each element must be a dict - a string element goes
    # through check_type_dict (bare TypeError on failure, surfaced
    # verbatim as the module failure msg) and a parsed dict descends one
    # level into the sub-spec recursively. Elements that are neither
    # strings nor dicts fail with Ansible's own (format-arg-swapped)
    # "Value 'x' in the sub parameter field 'y' must be a ..." wording.
    private def check_no_log_walk(options : Hash(String, JSON::Any), provided : Hash(String, String), order : Array(String)?) : String?
      ordered_option_pairs(options, order).each do |name, spec|
        sub_spec = spec["options"]?.try(&.as_h?) || next
        wanted = spec["type"]?.try(&.as_s?) || "str"
        next unless wanted == "dict" ||
                    (wanted == "list" && spec["elements"]?.try(&.as_s?) == "dict")
        raw = provided[name]?
        next unless raw
        next if raw == Krikri::NONE_SENTINEL
        json = JSON.parse(raw) rescue nil
        error = no_log_walk_elements(sub_spec, json || JSON::Any.new(raw), name, wanted)
        return error if error
      end
      nil
    end

    # One option's (container-or-string) wire value against its
    # sub-spec. Ansible sees the decoded param: a list is iterated, anything
    # else is treated as a one-element list.
    private def no_log_walk_elements(sub_spec : Hash(String, JSON::Any), value : JSON::Any,
                                     arg_name : String, wanted_type : String) : String?
      elements = value.as_a? || [value]
      elements.each do |element|
        case raw = element.raw
        when String
          if error = check_type_dict_error(raw)
            return error
          end
          parsed = parsed_dict_value(raw)
          if parsed && (failure = no_log_walk_params(sub_spec, parsed))
            return failure
          end
        when Hash(String, JSON::Any)
          if failure = no_log_walk_params(sub_spec, element)
            return failure
          end
        else
          return "Value '#{python_value_repr(element)}' in the sub parameter field '#{arg_name}' " \
                 "must be a #{wanted_type}, not '#{python_class_name(element)}'"
        end
      end
      nil
    end

    # Recursion one level down: the parsed dict's values against the
    # sub-spec's own dict-shaped options (Ansible's
    # _list_no_log_values(sub_argument_spec, sub_param)).
    private def no_log_walk_params(spec : Hash(String, JSON::Any), params : JSON::Any) : String?
      return nil unless params_h = params.as_h?
      spec.each do |name, sub|
        sub_sub = sub["options"]?.try(&.as_h?) || next
        wanted = sub["type"]?.try(&.as_s?) || "str"
        next unless wanted == "dict" ||
                    (wanted == "list" && sub["elements"]?.try(&.as_s?) == "dict")
        value = params_h[name]? || next
        next if value.raw.nil?
        error = no_log_walk_elements(sub_sub, value, name, wanted)
        return error if error
      end
      nil
    end

    # check_type_dict's conversion semantics on a string: a "{"-leading
    # string must be a JSON object (Ansible also tries literal_eval - krikri
    # approximates the same way its top-level dict conversion already
    # does), a string containing "=" must be fully key=value shaped, and
    # anything else raises the bare "dictionary requested, could not
    # parse JSON or key=value" TypeError. Returns the error text, or nil
    # when the string parses.
    private def check_type_dict_error(raw : String) : String?
      if raw.strip.starts_with?("{")
        json = JSON.parse(raw) rescue nil
        return nil if json && json.as_h?
        return "unable to evaluate string as dictionary"
      end
      return kv_parse_error(raw) if raw.includes?("=")
      "dictionary requested, could not parse JSON or key=value"
    end

    # Ansible's key=value field splitter (quote- and escape-aware, fields
    # separated on commas/spaces): every field must carry an "=" or the
    # whole string fails with the "key=value format" wording.
    private def kv_parse_error(raw : String) : String?
      fields = kv_fields(raw)
      fields.each do |field|
        return "unable to evaluate string in the \"key=value\" format as dictionary" unless field.includes?("=")
      end
      nil
    end

    private def kv_fields(raw : String) : Array(String)
      fields = [] of String
      field_buffer = ""
      in_quote = nil
      in_escape = false
      raw.strip.each_char do |char|
        if in_escape
          field_buffer += char
          in_escape = false
        elsif char == '\\'
          in_escape = true
        elsif in_quote.nil? && (char == '\'' || char == '"')
          in_quote = char
        elsif in_quote == char
          in_quote = nil
        elsif in_quote.nil? && (char == ',' || char == ' ')
          fields << field_buffer unless field_buffer.empty?
          field_buffer = ""
        else
          field_buffer += char
        end
      end
      fields << field_buffer unless field_buffer.empty?
      fields
    end

    # The parsed dict behind a string that check_type_dict accepted, for
    # the recursive sub-spec walk (nil when only the k=v shape was
    # validated without building a dict - the recursion then simply
    # finds no sub-values).
    private def parsed_dict_value(raw : String) : JSON::Any?
      if raw.strip.starts_with?("{")
        json = JSON.parse(raw) rescue nil
        return json if json && json.as_h?
        return nil
      end
      fields = kv_fields(raw)
      return nil unless fields.all?(&.includes?("="))
      object = Hash(String, JSON::Any).new
      fields.each do |field|
        key, value = field.split("=", 2)
        object[key] = JSON::Any.new(value)
      end
      JSON::Any.new(object)
    end

    # Python repr/str of a non-string, non-dict element value, for the
    # "Value '...' in the sub parameter field ..." wording (real embeds
    # str(value) there).
    private def python_value_repr(value : JSON::Any) : String
      case raw = value.raw
      when Nil                     then "None"
      when Bool                    then raw ? "True" : "False"
      when Int64                   then raw.to_s
      when Float64                 then raw.to_s
      when Array(JSON::Any)        then "[#{raw.map { |item| python_value_repr(item) }.join(", ")}]"
      when Hash(String, JSON::Any) then "{#{raw.map { |k, v| "'#{k}': #{python_value_repr(v)}" }.join(", ")}}"
      else                              raw.to_s
      end
    end

    private def python_class_name(value : JSON::Any) : String
      case value.raw
      when Nil              then "NoneType"
      when Bool             then "bool"
      when Int64            then "int"
      when Float64          then "float"
      when Array(JSON::Any) then "list"
      else                       "str"
      end
    end

    # One wire value -> Ansible's typed view. The wire is strings-only, so
    # the JSON container shapes a whole-span native param carries are
    # decoded here (Ansible sees the actual list/dict; krikri sees its JSON
    # text). A YAML boolean rides as exactly "true"/"false" - Ansible sees
    # a Python bool, which is an int subclass and passes int/float/list
    # checks but fails dict conversion.
    private def type_error(name : String, wanted : String, raw : String, spec : JSON::Any, native : JSON::Any? = nil) : String?
      is_null = raw == Krikri::NONE_SENTINEL
      # Ansible skips type conversion entirely for a None that is neither
      # required nor defaulted ("if value is None and not required and
      # default is None: continue").
      if is_null
        return none_type_error(name, wanted, spec)
      end

      if wanted == "str_or_list_of_str"
        return str_or_list_type_error(name, raw, native)
      end

      json = (JSON.parse(raw) rescue nil)
      kind = value_kind(raw, json) # Observed behavior: str | :bool | :list | :dict

      conversion_type_error(name, wanted, raw, kind, native)
    end

    # The per-wanted-type dispatch (Ansible's checker selection). Keeps
    # type_error itself under the complexity limit now that the
    # int-callable branch joined the chain.
    private def conversion_type_error(name : String, wanted : String, raw : String, kind : Symbol, native : JSON::Any?) : String?
      if wanted == "bool"
        bool_type_error(name, raw, kind)
      elsif wanted == "int"
        int_type_error(name, raw, kind, native)
      elsif wanted == "int_callable"
        int_callable_type_error(name, raw, kind, native)
      elsif wanted == "str_no_conversion"
        str_no_conversion_type_error(name, raw, kind, native)
      elsif wanted == "float"
        float_type_error(name, raw, kind)
      elsif wanted == "dict"
        dict_type_error(name, raw, kind)
      elsif wanted == "list"
        list_type_error(name, kind)
      elsif wanted == "jsonarg"
        jsonarg_type_error(name, kind)
      elsif wanted == "bytes" || wanted == "bits"
        size_type_error(name, wanted, raw, kind)
      end
    end

    private def none_type_error(name : String, wanted : String, spec : JSON::Any) : String?
      required = spec["required"]?.try(&.as_bool?) || false
      has_default = spec["default"]? != nil
      return nil if !required && !has_default
      # Ansible's checker for None: str converts to "" (no error); bool/
      # float/dict/list/jsonarg raise "<class 'NoneType'> cannot be
      # converted to ..."; int goes through Decimal and reprs the
      # value ('"None" cannot be converted to an int').
      return nil if wanted == "str" || wanted == "path" || wanted == "raw" || wanted == "any"
      tail = case wanted
             when "int"     then "\"None\" cannot be converted to an int"
             when "jsonarg" then "<class 'NoneType'> cannot be converted to a json string"
             else                "<class 'NoneType'> cannot be converted to #{a_word(wanted)}"
             end
      "argument '#{name}' is of type NoneType and we were unable to convert to #{wanted}: #{tail}"
    end

    private def bool_type_error(name : String, raw : String, kind : Symbol) : String?
      if kind == :str
        normalized = raw.downcase.strip
        return nil if REAL_TRUE.includes?(normalized) || REAL_FALSE.includes?(normalized)
        return "argument '#{name}' is of type str and we were unable to convert to bool: " \
               "The value '#{raw}' is not a valid boolean. Valid booleans include: #{BOOLEANS_REPR.join(", ")}"
      end
      if kind == :list || kind == :dict
        return "argument '#{name}' is of type #{kind} and we were unable to convert to bool: " \
               "<class '#{kind}'> cannot be converted to a bool"
      end
      # Observed behavior: bool - already a boolean, nothing to convert.
      nil
    end

    private def int_type_error(name : String, raw : String, kind : Symbol, native : JSON::Any?) : String?
      # A marked non-string YAML literal keeps its own class, which the
      # demoted wire text alone cannot express: an int (and a bool, being
      # an int subclass) converts, a float does not.
      if native
        return nil unless native.raw.is_a?(Float64)
        return "argument '#{name}' is of type float and we were unable to convert to int: " \
               "\"#{python_value_repr(native)}\" cannot be converted to an int"
      end
      case kind
      when :bool
        nil # bool IS an int in Python
      when :str
        return nil if int_like?(raw)
        "argument '#{name}' is of type str and we were unable to convert to int: " \
        "\"'#{raw}'\" cannot be converted to an int"
      else
        "argument '#{name}' is of type #{kind} and we were unable to convert to int: " \
        "\"#{python_repr(kind, raw)}\" cannot be converted to an int"
      end
    end

    # pause's minutes/seconds ride the int CALLABLE (not the 'int' string
    # type) in the action's own spec - native floats truncate (int(1.5)
    # == 1) and bools pass (int(True) == 1), but a string goes through
    # int(str) DIRECTLY, so "1.5" fails with int()'s raw ValueError text
    # ("invalid literal for int() with base 10: '1.5'") where the 'int'
    # string type's Decimal-based checker would report the "'1.5'"-quoted
    # form instead. A container raises int()'s own TypeError wording.
    private def int_callable_type_error(name : String, raw : String, kind : Symbol, native : JSON::Any?) : String?
      case native.try(&.raw)
      when Int64, Int32, Float64, Bool
        return nil
      end
      case kind
      when :bool
        nil
      when :str
        return nil if int_like?(raw)
        "argument '#{name}' is of type str and we were unable to convert to int: " \
        "invalid literal for int() with base 10: '#{raw}'"
      else
        "argument '#{name}' is of type #{kind} and we were unable to convert to int: " \
        "int() argument must be a string, a bytes-like object or a real number, not '#{kind}'"
      end
    end

    # debug's `var:` rides the _check_type_str_no_conversion CALLABLE
    # (the Ansible module:44), not the 'str' type name: the checker
    # accepts a string and NOTHING else - no int()/str() coercion - so any
    # natively-typed value is rejected outright, with the checker's own
    # repr in the "we were unable to convert to <name>" slot and its
    # TypeError text behind it. A None value is skipped by the validator
    # itself (neither required nor defaulted), so a bare `var:` never
    # fails (live-verified vs 2.19.11: var: 5 / var: true / var: [a, b]).
    private def str_no_conversion_type_error(name : String, raw : String, kind : Symbol, native : JSON::Any?) : String?
      # A marked non-string YAML literal keeps its own class; an unmarked
      # wire value that is not a plain string is a container.
      return nil if native.nil? && kind == :str
      reported = native ? python_value_repr(native) : (kind == :list || kind == :dict ? python_repr(kind, raw) : raw)
      "argument '#{name}' is of type #{native ? python_class_name(native) : kind} and we were unable to convert to " \
      "_check_type_str_no_conversion: '#{reported}' is not a string and conversion is not allowed"
    end

    private def float_type_error(name : String, raw : String, kind : Symbol) : String?
      case kind
      when :bool
        nil
      when :str
        return nil if float_like?(raw)
        "argument '#{name}' is of type str and we were unable to convert to float: " \
        "<class 'str'> cannot be converted to a float"
      else
        "argument '#{name}' is of type #{kind} and we were unable to convert to float: " \
        "<class '#{kind}'> cannot be converted to a float"
      end
    end

    private def dict_type_error(name : String, raw : String, kind : Symbol) : String?
      case kind
      when :dict
        nil
      when :str
        # check_type_dict: JSON object, then literal_eval, then the
        # k1=v1,k2=v2 fallback - each failure has its own wording.
        if raw.strip.starts_with?("{")
          "argument '#{name}' is of type str and we were unable to convert to dict: " \
          "unable to evaluate string as dictionary"
        elsif raw.includes?("=")
          nil
        else
          "argument '#{name}' is of type str and we were unable to convert to dict: " \
          "dictionary requested, could not parse JSON or key=value"
        end
      else
        "argument '#{name}' is of type #{kind} and we were unable to convert to dict: " \
        "<class '#{kind}'> cannot be converted to a dict"
      end
    end

    private def list_type_error(name : String, kind : Symbol) : String?
      return nil unless kind == :dict
      "argument '#{name}' is of type dict and we were unable to convert to list: " \
      "<class 'dict'> cannot be converted to a list"
    end

    # Ansible's check_type_list runs the elements= checker on every element
    # inline; only int and dict elements are strict enough to ever fail
    # here (str/path/raw elements coerce leniently), so only those two
    # are mirrored. The first failing element's error wins, wrapped as
    # "Elements value for option ..." instead of "argument ..." (live-
    # verified vs 2.19.11: uri status_code [200, abc] / [1.5] / [null] /
    # [[1]]; openssl_csr subject_ordered [str, str] against
    # elements=dict - which beats required_together, both being
    # AnsibleModule init checks).
    private def elements_type_error(name : String, spec : JSON::Any, raw : String, native : JSON::Any?, native_list : JSON::Any?) : String?
      case spec["elements"]?.try(&.as_s?)
      when "int"
        element_values(raw, native, native_list).each do |element|
          if msg = int_element_error(name, element)
            return msg
          end
        end
      when "dict"
        element_values(raw, native, native_list).each do |element|
          if msg = dict_element_error(name, element)
            return msg
          end
        end
      end
      nil
    end

    # One element against the dict checker (Ansible's check_type_dict): a
    # dict passes, a string goes through the JSON/key=value conversion
    # (each failure its own wording), anything else fails with its
    # Python class ("<class 'int'> cannot be converted to a dict").
    private def dict_element_error(name : String, element : JSON::Any) : String?
      case raw = element.raw
      when Hash(String, JSON::Any)
        nil
      when String
        if msg = check_type_dict_error(raw)
          return "Elements value for option '#{name}' is of type str and we were unable to convert to dict: #{msg}"
        end
        nil
      else
        kind = case raw
               when Int64, Int32 then "int"
               when Float64      then "float"
               when Bool         then "bool"
               when Nil          then "NoneType"
               else                   "list"
               end
        "Elements value for option '#{name}' is of type #{kind} and we were unable to convert to dict: " \
        "<class '#{kind}'> cannot be converted to a dict"
      end
    end

    # The list Ansible's check_type_list would hand to the element checker:
    # a natively-typed param is its own container (or a one-element list),
    # a JSON/demoted-YAML list decodes to its members, and a plain string
    # splits on commas (or stands alone) - see the native elements probes.
    private def element_values(raw : String, native : JSON::Any?, native_list : JSON::Any?) : Array(JSON::Any)
      if native
        return native.as_a? || [native]
      end
      return native_list.as_a if native_list && native_list.as_a?
      json = (JSON.parse(raw) rescue nil)
      return json.as_a if json && json.as_a?
      if raw.includes?(",")
        return raw.split(",").map { |part| JSON::Any.new(part) }
      end
      [JSON::Any.new(raw)]
    end

    # One element against the int checker: bools pass (a Python bool IS an
    # int), int-like values pass (real converts through Decimal, so "1.0"
    # and 1.0 convert and "abc"/1.5 do not), everything else fails with
    # its own Python class and repr.
    private def int_element_error(name : String, element : JSON::Any) : String?
      case raw = element.raw
      when Int64, Int32, Bool
        nil
      when Float64
        repr = python_value_repr(element)
        return nil if int_like?(repr)
        "Elements value for option '#{name}' is of type float and we were unable to convert to int: " \
        "\"#{repr}\" cannot be converted to an int"
      when String
        return nil if int_like?(raw)
        "Elements value for option '#{name}' is of type str and we were unable to convert to int: " \
        "\"'#{raw}'\" cannot be converted to an int"
      when Nil
        "Elements value for option '#{name}' is of type NoneType and we were unable to convert to int: " \
        "\"None\" cannot be converted to an int"
      else
        kind = element.as_a? ? "list" : "dict"
        "Elements value for option '#{name}' is of type #{kind} and we were unable to convert to int: " \
        "\"#{python_value_repr(element)}\" cannot be converted to an int"
      end
    end

    private def jsonarg_type_error(name : String, kind : Symbol) : String?
      return nil unless kind == :bool
      "argument '#{name}' is of type bool and we were unable to convert to jsonarg: " \
      "<class 'bool'> cannot be converted to a json string"
    end

    private def size_type_error(name : String, wanted : String, raw : String, kind : Symbol) : String?
      return nil unless kind == :str
      return nil if human_size_like?(raw)
      word = wanted == "bytes" ? "Byte value" : "Bit value"
      "argument '#{name}' is of type str and we were unable to convert to #{wanted}: " \
      "<class 'str'> cannot be converted to a #{word}"
    end

    private def value_kind(raw : String, json : JSON::Any?) : Symbol
      return :bool if raw == "true" || raw == "false"
      return :list if json && json.as_a?
      return :dict if json && json.as_h?
      :str
    end

    # Python repr of a list/dict wire value, for the error messages that
    # embed repr(value) (the int conversion's, debug's var conversion's).
    # String members/values are single-quoted the way Python's repr does
    # it; everything else goes through python_value_repr.
    private def python_repr(kind : Symbol, raw : String) : String
      return raw unless kind == :list || kind == :dict
      json = JSON.parse(raw) rescue return raw
      String.build do |io|
        io << (kind == :list ? "[" : "{")
        first = true
        if kind == :list
          json.as_a.each do |item|
            io << ", " unless first
            first = false
            io << python_repr_value(item)
          end
        else
          json.as_h.each do |k, v|
            io << ", " unless first
            first = false
            io << "'" << k << "': " << python_repr_value(v)
          end
        end
        io << (kind == :list ? "]" : "}")
      end
    end

    private def python_repr_value(value : JSON::Any) : String
      value.as_s? || python_value_repr(value)
    end

    private def python_word(wanted : String) : String
      case wanted
      when "jsonarg" then "a json string"
      when "str"     then "str"
      else                "a #{wanted}"
      end
    end

    private def a_word(wanted : String) : String
      case wanted
      when "int", "bool", "float", "dict", "list", "str" then "a #{wanted}"
      when "jsonarg"                                     then "a json string"
      else                                                    "a #{wanted}"
      end
    end

    # decimal.Decimal-compatible integer shape: the value must equal its
    # own integer truncation ("1.0" passes, "1.5" and "abc" fail).
    private def int_like?(raw : String) : Bool
      s = raw.strip
      begin
        bd = BigDecimal.new(s)
        (bd - BigDecimal.new(bd.to_i)) == BigDecimal.new(0)
      rescue
        false
      end
    end

    private def float_like?(raw : String) : Bool
      s = raw.strip
      return false if s.empty?
      begin
        s.to_f64
        true
      rescue
        false
      end
    end

    # human_to_bytes accepts a bare integer or a <number><unit> size
    # (K/M/G/T/P/E, optional i and B); anything else fails conversion.
    private def human_size_like?(raw : String) : Bool
      s = raw.strip
      return true if s.matches?(/\A[0-9]+\z/)
      s.matches?(/\A[0-9]+(\.[0-9]+)?\s*[KMGTPE](i)?B?\z/i)
    end

    private def check_choices(options : Hash(String, JSON::Any), provided : Hash(String, String), order : Array(String)? = nil) : String?
      ordered_option_pairs(options, order).each do |name, spec|
        raw = provided[name]?
        next unless raw
        choices = spec["choices"]?.try(&.as_a?) || next
        allowed = choices_strings(choices)
        # Ansible runs _validate_argument_values on the ALREADY
        # type-converted parameters, and its list branch is guarded by
        # `isinstance(parameters[param], list)` - which every option
        # declared `type: list` satisfies, because check_type_list has
        # already comma-split a scalar by then. So a scalar given to a
        # list+choices option reports the PER-MEMBER wording (the list
        # comment in Ansible's code says as much: "Allow one or more when
        # type='list' param with choices"), not the single-value one -
        # `deb822_repository: types: <not deb|deb-src>` fails with "must
        # be one or more of: ... Got no match for: <value>".
        json = JSON.parse(raw) rescue nil
        members =
          if arr = json.try(&.as_a?)
            arr
          elsif spec["type"]?.try(&.as_s?) == "list"
            raw.split(',')
          end
        if members
          missing = members.map(&.to_s).reject { |item| allowed.includes?(item) }
          unless missing.empty?
            return "value of #{name} must be one or more of: #{allowed.join(", ")}. " \
                   "Got no match for: #{missing.join(", ")}"
          end
        else
          value = raw == Krikri::NONE_SENTINEL ? "None" : raw
          unless allowed.includes?(value)
            return "value of #{name} must be one of: #{allowed.join(", ")}, got: #{value}"
          end
        end
      end
      nil
    end

    private def choices_strings(choices : Array(JSON::Any)) : Array(String)
      choices.map do |choice|
        case raw = choice.raw
        when Bool   then raw ? "True" : "False"
        when Nil    then "None"
        when String then raw
        else             choice.to_s
        end
      end
    end

    # Presence for the group checks: provided, or a non-null spec default
    # (Ansible's first _set_defaults pass runs before these checks).
    private def present?(name : String, provided : Hash(String, String), defaults : Hash(String, JSON::Any)) : Bool
      return true if provided.has_key?(name)
      if d = defaults[name]?
        return !d.raw.nil?
      end
      false
    end

    private def check_required_together(entry : JSON::Any, provided : Hash(String, String), defaults : Hash(String, JSON::Any)) : String?
      groups = entry["required_together"]?.try(&.as_a?) || return nil
      failing = [] of Array(String)
      groups.each do |group|
        names = group.as_a.map(&.as_s)
        present_count = names.count { |name| present?(name, provided, defaults) }
        failing << names if present_count > 0 && present_count < names.size
      end
      failing.empty? ? nil : "parameters are required together: #{failing.map(&.join(", ")).join(", ")}"
    end

    private def check_required_one_of(entry : JSON::Any, provided : Hash(String, String), defaults : Hash(String, JSON::Any)) : String?
      groups = entry["required_one_of"]?.try(&.as_a?) || return nil
      groups.each do |group|
        names = group.as_a.map(&.as_s)
        unless names.any? { |name| present?(name, provided, defaults) }
          return "one of the following is required: #{names.join(", ")}"
        end
      end
      nil
    end

    private def check_required_if(entry : JSON::Any, provided : Hash(String, String), defaults : Hash(String, JSON::Any)) : String?
      requirements = entry["required_if"]?.try(&.as_a?) || return nil
      requirements.each do |req|
        parts = req.as_a
        key = parts[0].as_s
        val = parts[1]
        reqs = parts[2].as_a.map(&.as_s)
        is_one_of = parts.size > 3 && parts[3].as_bool

        # The triggering value: provided wire value, else the spec
        # default (real compares parameters[key] == val after defaults).
        current = provided[key]?
        current = default_value_string(defaults[key]) if current.nil? && defaults[key]?
        next unless current
        next unless value_matches?(current, val)

        missing = reqs.reject { |needed| present?(needed, provided, defaults) }
        max_missing = is_one_of ? reqs.size : 0
        if missing.size >= max_missing && !missing.empty?
          requires = is_one_of ? "any" : "all"
          return "#{key} is #{python_literal(val)} but #{requires} of the following are missing: #{missing.join(", ")}"
        end
      end
      nil
    end

    private def value_matches?(current : String, val : JSON::Any) : Bool
      case raw = val.raw
      when Bool   then current == (raw ? "true" : "false")
      when String then current == raw
      when Int    then current == raw.to_s
      when Float  then current == raw.to_s
      else             false
      end
    end

    # Python "%s"-style rendering of a required_if trigger value
    # (booleans print True/False, strings print bare).
    private def python_literal(val : JSON::Any) : String
      case raw = val.raw
      when Bool   then raw ? "True" : "False"
      when Nil    then "None"
      when String then raw
      else             val.to_s
      end
    end

    private def default_value_string(value : JSON::Any) : String
      case raw = value.raw
      when Bool   then raw ? "true" : "false"
      when Nil    then Krikri::NONE_SENTINEL
      when String then raw
      else             value.to_s
      end
    end

    private def check_required_by(entry : JSON::Any, provided : Hash(String, String), defaults : Hash(String, JSON::Any)) : String?
      requirements = entry["required_by"]?.try(&.as_h?) || return nil
      requirements.each do |key, value|
        next unless present?(key, provided, defaults)
        needed = value.as_a?.try(&.map(&.as_s)) || [value.as_s]
        missing = needed.reject { |req| present?(req, provided, defaults) }
        unless missing.empty?
          return "missing parameter(s) required by '#{key}': #{missing.join(", ")}"
        end
      end
      nil
    end

    # Ansible's UnsupportedError wording: the offending names sorted, then
    # the spec's own option names sorted with ONE trailing parenthetical
    # holding all the spec's aliases sorted together.
    private def unsupported_params_message(print_name : String, unsupported : Array(String), options : Hash(String, JSON::Any)) : String
      names = options.keys.sort!
      aliases = [] of String
      options.each_value do |spec|
        if list = spec["aliases"]?.try(&.as_a?)
          list.each { |a| aliases << a.as_s }
        end
      end
      aliases.sort!
      supported = aliases.empty? ? names.join(", ") : "#{names.join(", ")} (#{aliases.join(", ")})"
      "Unsupported parameters for (#{print_name}) module: #{unsupported.sort.join(", ")}. " \
      "Supported parameters include: #{supported}."
    end

    # Action-only directives with a fixed supported set (debug/pause/
    # script): same message shape, but the list is the hand-probed one.
    private def virtual_supported_failure(
      action_name : String,
      print_name : String,
      entry : JSON::Any,
      params : Hash(String, String),
      supported : Array(JSON::Any),
    ) : Failure?
      unsupported = params.keys.reject do |key|
        key.starts_with?("_ansible_") || INTERNAL_KEYS.includes?(key) ||
          supported.map(&.as_s).includes?(key)
      end.sort!
      return nil if unsupported.empty?
      Failure.new(
        "Unsupported parameters for (#{print_name}) module: #{unsupported.join(", ")}. " \
        "Supported parameters include: #{supported.map(&.as_s).join(", ")}.",
        action_level: entry["action_level"]?.try(&.as_bool?) || false,
        omit_changed: entry["result_keys"]?.try(&.as_a?) == ["msg"],
      )
    end

    # fail/group_by/wait_for_connection: the action plugin's own
    # "Invalid options for <action>: <names>" check (comma, no space,
    # Ansible's ','.join of the offending set).
    private def virtual_invalid_options_failure(print_name : String, params : Hash(String, String), valid : Array(String)) : Failure?
      unsupported = params.keys.reject do |key|
        key.starts_with?("_ansible_") || INTERNAL_KEYS.includes?(key) || valid.includes?(key)
      end.sort!
      return nil if unsupported.empty?
      Failure.new("Invalid options for #{print_name}: #{unsupported.join(",")}", action_level: true)
    end
  end
end
