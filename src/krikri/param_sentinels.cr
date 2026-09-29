# Shared between the executor's param-finalization path (variable_
# substitutor.cr) and the plugin-side BasePlugin param parsing, which
# compile into DIFFERENT binaries (krikri-playbook vs each bin/plugins/*
# binary) and share no other file that both already require - so the
# sentinel constant lives here, in the one file both sides can require
# without dragging the whole substitutor (Crinja and all) into every
# plugin binary or base_plugin into the main executable.
module Krikri
  # The null/None counterpart to OMIT_SENTINEL (variable_substitutor.cr).
  # The param wire between the executor and a plugin binary is
  # strings-only, so a module call whose param natively resolved to
  # Python None (`enablerepo: "{{ item.enablerepo | default('') }}"` with
  # a null item field - round 900905 officel.httpd) would collapse to the
  # same "" as a real empty string, which real Ansible's argument specs
  # treat completely differently (an explicit None fails every `type:
  # list` param; an empty string coerces to an empty list just fine -
  # live-verified against ansible-core 2.19.11). The executor marks such
  # params with this sentinel, BasePlugin demotes it back to "" (plus a
  # null bookkeeping entry) so every plugin that never asks about it
  # stays behavior-identical, and only plugins that mirror a real
  # module's argspec consult BasePlugin#explicit_null_param?.
  NONE_SENTINEL = "__crystal_ansible_none__"

  # Prefix marking a set_fact param value as the JSON encoding of the
  # expression's NATIVELY-TYPED result, not substituted display text.
  # The executor's param wire is strings-only, so a whole-single-span
  # `{{ expr }}` set_fact value (the only shape real ansible-core 2.19
  # native-typing keeps unstringified) would otherwise arrive at the
  # set_fact plugin as bare text and get re-coerced by string shape -
  # which is pre-2.19 `ANSIBLE_JINJA2_NATIVE=off` literal_eval behavior,
  # not 2.19's "the expression's own type is the value's type" rule: a
  # Jinja string expression stays a str even when it looks like a number
  # (pluggero.openssh round 981024: "{{ '8.9' }}" became the float 8.9,
  # so `openssh_installed_version != openssh_pkg_mgr_version` compared
  # float-to-str and was always true, forcing a package reinstall every
  # run). The control character makes a false positive on a *literal*
  # (non-templated) set_fact value - which still takes the legacy
  # string-shape coercion below - effectively impossible.
  NATIVE_TYPED_PREFIX = "\u{E000}native:"

  # Prefix marking a module-arg value as a NON-STRING YAML scalar literal -
  # an int, float or bool the playbook wrote unquoted (`copy: dest: 89`,
  # `fetch: src: true`, `debug: msg: 1.5`-style). Task#params is a
  # strings-only wire (Hash(String, String)), so stringify_value erases the
  # YAML type at parse time - and with it every behavior that hinges on the
  # value's Python type rather than its text: real ansible-core 2.19 passes
  # the literal AS ITS NATIVE TYPE into the action plugin, so a non-string
  # dest/src crashes real's copy with "'_AnsibleTaggedInt' object has no
  # attribute 'startswith'" (bools print as plain 'bool' - they are not
  # tagged), fails fetch's action with "Invalid type supplied for dest
  # option, it must be a string", renders through template as Python
  # str(True) = "True" (not YAML's "true"), and makes falsy scalars (false,
  # 0, 0.0) count as "not provided" in copy's truthiness checks
  # (live-verified against 2.19.11 for the full dest/src x int/bool/float
  # matrix). The parser prefixes such a literal with this control character
  # plus the JSON encoding of the parsed YAML value; BasePlugin strips it
  # back to the exact same plain string every plugin saw before (so no
  # plugin that never asks changes behavior) and records the native value
  # for the plugins that mirror real's type-checking - query it with
  # BasePlugin#non_string_param. Like NATIVE_TYPED_PREFIX, the leading
  # private-use control character makes a false positive on real user data
  # effectively impossible, and templated values (any `{{`/`{%`/`{#`)
  # are never marked - their type belongs to the executor's whole-span
  # evaluation, not to the literal.
  NON_STRING_PARAM_PREFIX = "\u{E000}nonstring:"

  # Decodes a NON_STRING_PARAM_PREFIX-prefixed param value back into the
  # native YAML scalar (JSON::Any wrapping Int64/Float64/Bool), or nil when
  # the value is not a marked literal. Shared by BasePlugin's param parse
  # (plugin binaries) and the executor/ArgspecValidator side (main
  # executable) - the one file both can require.
  def self.non_string_scalar(value : String?) : JSON::Any?
    return nil unless value && value.starts_with?(NON_STRING_PARAM_PREFIX)
    JSON.parse(value[NON_STRING_PARAM_PREFIX.size..])
  rescue
    nil
  end

  # The plain string form a marked literal demotes to on the plugin wire -
  # exactly what stringify_value produced before the marker existed, so
  # every plugin that never asks about the native type sees identical text.
  def self.non_string_param_text(native : JSON::Any) : String
    case native.raw
    when Int64, Int32, Float64, Bool then native.raw.to_s
    else                                  native.to_s
    end
  end

  # Executor-side demotion: every param value the parser marked as a
  # non-string YAML literal is stripped back to its plain string form, so
  # the spec checks (and every other executor-side consumer) see exactly
  # the text they always did. Returns the same hash object when nothing is
  # marked (the common case - no copying).
  def self.strip_non_string_param_markers(params : Hash(String, String)) : Hash(String, String)
    return params unless params.each_value.any? { |v| v.starts_with?(NON_STRING_PARAM_PREFIX) }
    params.transform_values do |value|
      if (native = non_string_scalar(value))
        non_string_param_text(native)
      else
        value
      end
    end
  end

  # Python truthiness of a task-param value, native-type aware: a marked
  # non-string literal carries its own truthiness (false/0/0.0 are falsy
  # exactly like in Python), a nil/absent param is falsy, and a plain
  # string is falsy only when empty - matching Python's bool("") without
  # changing what any existing plugin saw (they got the same "" before).
  def self.python_param_truthy?(value : String?) : Bool
    return false if value.nil? || value.empty?
    if native = non_string_scalar(value)
      case native.raw
      when Bool    then native.as_bool
      when Int64   then native.as_i64 != 0
      when Float64 then native.as_f != 0.0
      else              true
      end
    else
      true
    end
  end

  # Python str() of a marked non-string scalar - the coercion real's action
  # plugins effectively put dest/src through when they use a non-string
  # literal as text (template's `dest: true` writes a file named "True",
  # not "true" - live-verified vs 2.19.11; int/float spellings are
  # identical to the demoted text).
  def self.python_str_scalar(native : JSON::Any) : String
    case native.raw
    when Bool then native.as_bool ? "True" : "False"
    else           non_string_param_text(native)
    end
  end

  # The Python type name real ansible-core 2.19 reports for a non-string
  # scalar literal in an "'X' object has no attribute ..." crash: YAML
  # ints/floats arrive natively tagged (_AnsibleTaggedInt/_AnsibleTaggedFloat),
  # bools are plain Python bools (live-verified vs 2.19.11).
  def self.python_scalar_type_name(native : JSON::Any) : String
    case native.raw
    when Int64, Int32 then "_AnsibleTaggedInt"
    when Float64      then "_AnsibleTaggedFloat"
    when Bool         then "bool"
    else                   native.raw.class.to_s
    end
  end

  # The FULL Python class path real's inventory layer reports for a
  # non-string scalar host name - Inventory.add_host's
  # "expected a string but got %s for %s" formats type(host), which is
  # the fully-qualified class, not the short name the task-executor
  # crash messages use (live-verified vs 2.19.11).
  def self.python_scalar_class_path(native : JSON::Any) : String
    case native.raw
    when Int64, Int32 then "ansible.module_utils._internal._datatag._AnsibleTaggedInt"
    when Float64      then "ansible.module_utils._internal._datatag._AnsibleTaggedFloat"
    when Bool         then "bool"
    else                   native.raw.class.to_s
    end
  end
end
