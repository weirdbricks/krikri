# Shared between the executor's param-finalization path (variable_
# substitutor.cr) and the plugin-side BasePlugin param parsing, which
# compile into DIFFERENT binaries (krikri-playbook vs each bin/plugins/*
# binary) and share no other file that both already require - so the
# sentinel constant lives here, in the one file both sides can require
# without dragging the whole substitutor (Crinja and all) into every
# plugin binary or base_plugin into the main executable.
require "base64"

module Krikri
  # The null/None counterpart to OMIT_SENTINEL (variable_substitutor.cr).
  # The param wire between the executor and a plugin binary is
  # strings-only, so a module call whose param natively resolved to
  # Python None (`enablerepo: "{{ item.enablerepo | default('') }}"` with
  # a null item field - round 900905 officel.httpd) would collapse to the
  # same "" as a real empty string, which Ansible's argument specs
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
  # `{{ expr }}` set_fact value (the only shape ansible-core 2.19
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
  # value's Python type rather than its text: ansible-core 2.19 passes
  # the literal AS ITS NATIVE TYPE into the action plugin, so a non-string
  # dest/src crashes Ansible's copy with "'_AnsibleTaggedInt' object has no
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
  # for the plugins that mirror Ansible's type-checking - query it with
  # BasePlugin#non_string_param. Like NATIVE_TYPED_PREFIX, the leading
  # private-use control character makes a false positive on real user data
  # effectively impossible, and templated values (any `{{`/`{%`/`{#`)
  # are never marked - their type belongs to the executor's whole-span
  # evaluation, not to the literal.
  NON_STRING_PARAM_PREFIX = "\u{E000}nonstring:"

  # The MEMBER counterpart: the parser's comma-joined list branch marks a
  # non-string scalar list member with THIS prefix instead, so a
  # single-element list whose only member is a non-string (`parents: [7]`)
  # stays distinguishable from the whole-value scalar literal (`parents:
  # 7`) that Ansible crashes on DIFFERENTLY ("object is not iterable"
  # vs "object has no attribute 'replace'"). The demotion sites treat both
  # prefixes identically - decode the JSON payload, emit the exact
  # stringify_value text - so no plugin that never asks changes behavior;
  # only the executor-side hooks mirroring Ansible's member-iterating action
  # plugins (group_by/add_host) tell them apart.
  NON_STRING_MEMBER_PREFIX = "\u{E000}nonmember:"

  # Prefix marking a param value whose bytes are NOT valid UTF-8 - binary
  # module-arg data such as a slurp+b64decode'd corosync authkey passed as
  # `copy: content:` (bloxberg.corosync_pacemaker, issue #835). The plugin
  # wire is JSON, and a Crystal JSON round trip mangles invalid-UTF-8
  # strings (observed: 32 random authkey bytes became 52 bytes sprinkled
  # with U+FFFD sequences), so real ansible's "content equals what the
  # file already holds -> ok" idempotency check failed here and every run
  # rewrote the file as changed. The executor base64-encodes any param
  # string that fails `valid_encoding?` under this prefix before the
  # config JSON is built (base64 output is pure ASCII, so every later JSON
  # encode/parse round trip - including the remote transport's own - is
  # lossless), and BasePlugin demotes it back to the exact original bytes
  # when the plugin process parses its config. Like the other prefixes,
  # the leading private-use control character makes a false positive on
  # real user data effectively impossible.
  BINARY_WIRE_PREFIX = "\u{E000}binary:"

  # Executor-side encode: passes valid-UTF-8 text through untouched (the
  # common case - no behavior change), base64-wraps everything else.
  def self.encode_binary_wire_value(value : String) : String
    return value if value.valid_encoding?
    BINARY_WIRE_PREFIX + Base64.strict_encode(value)
  end

  # Plugin-side decode: restores the exact original bytes behind an
  # encoded value; anything not carrying the prefix is returned as-is.
  def self.decode_binary_wire_value(value : String) : String
    return value unless value.starts_with?(BINARY_WIRE_PREFIX)
    Base64.decode_string(value[BINARY_WIRE_PREFIX.size..])
  rescue
    value
  end

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

  # Same decode for a NON_STRING_MEMBER_PREFIX-prefixed list member (or a
  # single-member list whose whole wire value carries the member prefix).
  def self.non_string_member_scalar(value : String?) : JSON::Any?
    return nil unless value && value.starts_with?(NON_STRING_MEMBER_PREFIX)
    JSON.parse(value[NON_STRING_MEMBER_PREFIX.size..])
  rescue
    nil
  end

  # The members of a parser comma-joined list param value, in wire
  # order: a member the parser marked with NON_STRING_MEMBER_PREFIX (see
  # that prefix's comment) as its decoded native scalar, every other
  # member as its own plain text. nil when the value carries no member
  # marker at all - a plain string, or a whole-value scalar literal
  # (which rides NON_STRING_PARAM_PREFIX instead and stays
  # #non_string_scalar's business). The plugin-side counterpart of the
  # demotion every param-parse site performs: a plugin mirroring a real
  # module's per-MEMBER type checking can still see the native types
  # here, since the demoted @params text has lost the markers.
  def self.non_string_list_members(value : String?) : Array(JSON::Any)?
    return nil unless value && value.includes?(NON_STRING_MEMBER_PREFIX)
    value.split(',').map do |part|
      non_string_member_scalar(part) || JSON::Any.new(part)
    end
  end

  # The plain string form a marked literal demotes to on the plugin wire.
  # Bools render as Python str() ("True"/"False") - what Ansible's argspec
  # finalization puts on the wire for a str-typed option carrying a native
  # bool literal (2.21 live-verified: `cmd: false` executes the literally-
  # named "False", rc 2 ENOENT) - matching #python_str_scalar, whose
  # template's-dest note records the same behavior live-verified against
  # 2.19.11. Int/float spellings are identical either way. A marked nil
  # (YAML `key:` with no value) demotes to "" like stringify_value's own
  # Nil case - the explicit-null argspec flow handles real Nones.
  def self.non_string_param_text(native : JSON::Any) : String
    case native.raw
    when Bool                  then native.as_bool ? "True" : "False"
    when Int64, Int32, Float64 then native.raw.to_s
    when Nil                   then ""
    else                            native.to_s
    end
  end

  # The plugin-side view of BasePlugin#initialize's param parse, for the
  # callers that read the RAW config JSON rather than the demoted
  # @params hash - the FactsGatherer behind `setup:`/`facts:` does
  # exactly that, and used to see a `gather_timeout: 75` written
  # unquoted in the playbook as the literal STRING
  # "nonstring:75" (the parser's marker rides the strings-only
  # wire), so a type-specific read failed the module with "argument
  # 'gather_timeout' is of type str and we were unable to convert to
  # int" where Ansible - which converts the native int - happily
  # gathers. Restores each marked literal to the JSON value it stood
  # for, exactly as the demotion sites above do, so a reader sees the
  # same numbers/lists/strings the playbook actually wrote.
  def self.restore_native_param_values(params : JSON::Any?) : JSON::Any?
    hash = params.try(&.as_h?)
    return params unless hash
    return params unless hash.each_value.any? do |value|
                           text = value.as_s?
                           text && (text.includes?(NON_STRING_PARAM_PREFIX) || text.includes?(NON_STRING_MEMBER_PREFIX))
                         end

    JSON::Any.new(hash.transform_values { |value| restore_native_param_value(value) })
  end

  # One param value's restoration: a whole-value marked literal goes
  # back to the JSON value it encoded (an int/float/bool keeps its
  # type, which is the whole point - a JSON number no longer looks like
  # a string to as_i64?/as_bool?), and a comma-joined list's marked
  # members go back to their own plain text. Anything unmarked is
  # returned untouched.
  def self.restore_native_param_value(value : JSON::Any) : JSON::Any
    text = value.as_s?
    return value unless text
    if native = non_string_scalar(text)
      return native
    end
    return value unless text.includes?(NON_STRING_MEMBER_PREFIX)

    JSON::Any.new(text.split(',').map do |part|
      JSON::Any.new(non_string_param_text(non_string_member_scalar(part) || JSON::Any.new(part)))
    end)
  end

  # Executor-side demotion: every param value the parser marked as a
  # non-string YAML literal is stripped back to its plain string form, so
  # the spec checks (and every other executor-side consumer) see exactly
  # the text they always did. Returns the same hash object when nothing is
  # marked (the common case - no copying).
  def self.strip_non_string_param_markers(params : Hash(String, String)) : Hash(String, String)
    return params unless params.each_value.any? do |v|
                           v.includes?(NON_STRING_PARAM_PREFIX) || v.includes?(NON_STRING_MEMBER_PREFIX)
                         end
    params.transform_values do |value|
      strip_non_string_markers_in_value(value)
    end
  end

  # Demotes every non-string marker in ONE param value: a whole-value
  # marked literal (either prefix at the very start, its JSON payload
  # consuming the entire rest) back to its plain scalar text, and - since
  # the parser's comma-joined list branch marks non-string MEMBERS in
  # place - marked members inside a comma-joined list back to their own
  # plain text. The comma-join invariant (a scalar JSON payload never
  # contains a comma) keeps the split exact, and a marker occurrence whose
  # payload does not parse as a complete JSON document can only sit in a
  # member position ("\u{E000}nonmember:7,g1"), so the member path takes
  # over.
  def self.strip_non_string_markers_in_value(value : String) : String
    return value unless value.includes?(NON_STRING_PARAM_PREFIX) || value.includes?(NON_STRING_MEMBER_PREFIX)
    if (native = non_string_scalar(value)) || (native = non_string_member_scalar(value))
      return non_string_param_text(native)
    end
    value.split(',').map do |part|
      if (native = non_string_scalar(part)) || (native = non_string_member_scalar(part))
        non_string_param_text(native)
      else
        part
      end
    end.join(',')
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
      when Nil     then false
      else              true
      end
    else
      true
    end
  end

  # Ansible's boolean(value, strict=False) (the Ansible module
  # convert_bool.py) answering TRUE - the exact predicate the assemble
  # action plugin applies to remote_src to pick between its module branch
  # (truthy: the assemble module itself runs and re-converts remote_src
  # with its own strict type: bool, which can then only ever succeed) and
  # its controller-side branch (everything else: falsy spellings, invalid
  # spellings like 'timjjr', explicit None, native 2/0.5 - boolean()
  # returns False for all of them under strict=False, so the action
  # assembles locally and delegates the placement to the copy module,
  # whose spec - with remote_src STRIPPED - is what validates the rest).
  # Only BOOLEANS_TRUE counts: the spellings y/yes/on/1/true/t
  # (lowercased, whitespace-stripped) and the native true/1/1.0.
  def self.lenient_boolean_true?(value : String?) : Bool
    return false if value.nil? || value.empty? || value == NONE_SENTINEL
    if native = non_string_scalar(value)
      case native.raw
      when Bool    then native.as_bool
      when Int64   then native.as_i64 == 1
      when Float64 then native.as_f == 1.0
      else              false
      end
    else
      %w[y yes on 1 true t].includes?(value.downcase.strip)
    end
  end

  # Python str() of a marked non-string scalar - the coercion Ansible's action
  # plugins effectively put dest/src through when they use a non-string
  # literal as text (template's `dest: true` writes a file named "True",
  # not "true" - live-verified vs 2.19.11; int/float spellings are
  # identical to the demoted text).
  def self.python_str_scalar(native : JSON::Any) : String
    case native.raw
    when Bool then native.as_bool ? "True" : "False"
    when Nil  then "None"
    else           non_string_param_text(native)
    end
  end

  # The Python type name CPython's str.join puts in its own "sequence item
  # N: expected str instance, X found" TypeError - the message Ansible's
  # debconf module dies with when a non-string `value:` literal reaches its
  # `' '.join([pkg, question, vtype, value])` (debconf.py:179, live-verified
  # vs 2.19.11). These values are PLAIN Python objects by then - the same
  # `value:` literal that would be reported as an _AnsibleTaggedInt in an
  # "'X' object has no attribute" crash names plain `int` here - so this is
  # the builtin name, unlike #python_value_type_name.
  def self.python_join_type_name(native : JSON::Any) : String
    case native.raw
    when Int64, Int32 then "int"
    when Float64      then "float"
    when Bool         then "bool"
    when Nil          then "NoneType"
    when Hash         then "dict"
    when Array        then "list"
    else                   native.raw.class.to_s
    end
  end

  # The Python type name ansible-core 2.19 reports for ANY non-string
  # value in an "'X' object has no attribute ..." crash - scalars (see
  # #python_scalar_type_name) plus the container/None shapes a YAML list
  # member or `name:` value can carry (live-verified vs 2.19.11: dict and
  # list members report _AnsibleTaggedDict/_AnsibleTaggedList, a nil one
  # plain 'NoneType').
  def self.python_value_type_name(native : JSON::Any) : String
    case native.raw
    when Int64, Int32 then "_AnsibleTaggedInt"
    when Float64      then "_AnsibleTaggedFloat"
    when Bool         then "bool"
    when Nil          then "NoneType"
    when Hash         then "_AnsibleTaggedDict"
    when Array        then "_AnsibleTaggedList"
    else                   "str"
    end
  end

  # The Python type name ansible-core 2.19 reports for a non-string
  # scalar literal in an "'X' object has no attribute ..." crash: YAML
  # ints/floats arrive natively tagged (_AnsibleTaggedInt/_AnsibleTaggedFloat),
  # bools are plain Python bools (live-verified vs 2.19.11).
  def self.python_scalar_type_name(native : JSON::Any) : String
    case native.raw
    when Int64, Int32 then "_AnsibleTaggedInt"
    when Float64      then "_AnsibleTaggedFloat"
    when Bool         then "bool"
    when Nil          then "NoneType"
    else                   native.raw.class.to_s
    end
  end

  # The FULL Python class path Ansible's inventory layer reports for a
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

  # Prefix marking a string as the decimal text of an integer too wide for
  # Int64 (RSA moduli, EC coordinates, big certificate serial numbers).
  # JSON::Any's raw union tops out at Int64, so such a value cannot exist
  # as a number in the engine's result world: a module that returns a
  # Python int beyond Int64 reaches the controller as bare digits on the
  # JSON wire, the bigint-aware parse (Krikri::BigJson) stores it as this
  # marked string, and every renderer that prints a value to a user
  # (ResultDisplay's dumps, PyDump, the filters, string interpolation)
  # prints it as bare unquoted digits again - the exact text Ansible's
  # Python ints produce. The engine side (krikri-jinja) turns the marked
  # string into a real BigIntValue for templating/tests/comparisons; its
  # canonical constant is KrikriJinja::BIGINT_SENTINEL_PREFIX, duplicated
  # here because the plugin binaries (which also emit wide integers, and
  # mark them with this prefix before BasePlugin's wire rewrite unquotes
  # them) link neither that shard nor the jinja engine. The private-use
  # control character makes a false positive on real string data
  # effectively impossible.
  BIGINT_SENTINEL_PREFIX = "\u{E000}bigint:"

  # The decimal digits a BIGINT_SENTINEL_PREFIX-marked string carries
  # (sign included), or nil when the text is not a marked value. A prefix
  # occurrence with a non-integer payload (only possible via hostile
  # string data, never via the parse boundary) is not a bigint.
  def self.bigint_digits(text : String?) : String?
    return nil unless text && text.starts_with?(BIGINT_SENTINEL_PREFIX)
    digits = text[BIGINT_SENTINEL_PREFIX.size..]
    digits.matches?(/\A-?(0|[1-9]\d*)\z/) ? digits : nil
  end

  # The bigint-sentinel check over a JSON::Any node: the decimal digits
  # when the node is a marked string, nil otherwise.
  def self.bigint_digits(value : JSON::Any) : String?
    bigint_digits(value.as_s?)
  end

  # Builds the marked string for a decimal integer too wide for Int64.
  def self.bigint_sentinel(digits : String) : String
    BIGINT_SENTINEL_PREFIX + digits
  end

  # Rewrites every BIGINT_SENTINEL_PREFIX-marked string in serialized
  # JSON text to its bare digits: the wire form a module's Python int
  # takes. Used by BasePlugin#run_and_capture (plugin result -> wire) and
  # by the serializers that have no per-node hook (Crystal's own
  # JSON::Any#to_pretty_json, whose quoted-sentinel bytes this post-
  # processes back to unquoted digits).
  def self.unquote_bigint_json(text : String) : String
    return text unless text.includes?(BIGINT_SENTINEL_PREFIX)
    text.gsub(/"\x{E000}bigint:(-?(?:0|[1-9]\d*))"/) { $1 }
  end

  # Ordering comparison of two signed decimal integer strings of
  # arbitrary width (the payloads of BIGINT_SENTINEL_PREFIX-marked
  # values), for the comparison paths that must treat a marked value as
  # a real number. Sign first, then magnitude by length (a longer
  # magnitude is the larger number), then lexicographic on equal
  # lengths - exact, no Float64 rounding anywhere.
  def self.bigint_cmp(a : String, b : String) : Int32
    a_neg = a.starts_with?('-')
    b_neg = b.starts_with?('-')
    return -bigint_cmp(a[1..], b[1..]) if a_neg && b_neg
    return -1 if a_neg
    return 1 if b_neg
    a_mag = a
    b_mag = b
    return (a_mag.size <=> b_mag.size) || 0 if a_mag.size != b_mag.size
    a_mag <=> b_mag
  end
end
