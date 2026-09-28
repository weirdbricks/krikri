require "json"
require "../unsafe_values"
require "krikri-jinja/krikri_jinja"
require "../krikri_jinja_filters"
require "../jinja_host_context"
require "./filter_core"
require "time"
require "base64"
require "uri"
require "uuid"
require "openssl/digest"
require "../vault"
require "../py_random"
require "../python_filter_runner"
require "../ipaddr_core"
require "../jmespath"
require "./variable_lookup"
require "./expression_evaluator"
require "../variable_substitutor"
require "../filters/filter_dispatch"
require "../filters/filter_args"
require "../filters/filter_values"
require "../filters/filter_select"
require "../filters/filter_datetime"
require "../filters/filter_python"

module Krikri
  module VariableSubstitutor
    # FilterEngine - Applies Ansible/Jinja2-style filters to values.
    #
    # Operates on JSON::Any rather than String so a filter chain
    # (`{{ x | sort | join(',') }}`) can carry real array/hash structure
    # from one filter to the next - only the *final* result of the whole
    # chain gets stringified for template interpolation (by the caller, via
    # VariableLookup#format_value). Before this, the pipeline collapsed to a
    # String after every single filter and only ever split on the *first*
    # `|`, so `sort`'s own string-only output (`"[\"b\",\"a\"]"` as a JSON
    # string, not a real array) fed straight into `join`, which had no
    # array to actually join - chained filters were silently broken.
    class FilterEngine
      # Raised when a filter name is not implemented here (and, since
      # this engine is only ever the fallback path, not implemented by
      # Crinja either) - real Ansible's own "Syntax error in template:
      # No filter named 'x'." (verified against ansible-core 2.19),
      # which fails the task.
      class UnknownFilterError < Exception
      end

      # Raised when a role-local `filter_plugins/*.py` filter WAS found
      # and dispatched but the invocation itself failed (an exception
      # raised inside the filter). Subclasses UnknownFilterError so every
      # existing "rescue ex : UnknownFilterError" clean-task-failure site
      # catches it unchanged - but the message carries the filter's own
      # failure rather than the misleading "No filter named 'X'.": real
      # Ansible fails the task with "The filter plugin 'xrt_latest'
      # failed: No XRT version found for this OS" (live-verified against
      # ansible-core 2.19, Accelize.aws_fpga round 83177), never with an
      # unknown-filter error for a filter it just successfully ran.
      class FilterFailureError < UnknownFilterError
      end

      # Every filter name the `case filter_name` dispatch inside #apply
      # below implements. Lives alongside that dispatch as the one list
      # ConditionalEvaluator's compile-time filter-name pre-pass checks
      # against (a `when:` must hard-fail an unknown filter even when
      # short-circuiting never reaches the clause that uses it - real
      # Jinja resolves every filter name in the whole expression at
      # compile time, before any and/or evaluation). Kept in sync with
      # the dispatch by test/unit/conditional_filter_prepass_test.cr, which
      # applies every name here to a nil value and fails if any of them
      # raises UnknownFilterError (i.e. the dispatch stopped knowing a
      # name the list still advertises). Deliberately EXCLUDES names the
      # dispatch doesn't actually implement (the select()-style test names
      # like equalto/match/truthy that #item_matches_test? handles for
      # select/reject arguments but that are not themselves top-level
      # filters) - advertising one of those here would make the pre-pass
      # silently pass a `when:` that still hard-fails the moment its clause
      # is actually evaluated, the exact inconsistency the pre-pass exists
      # to eliminate. (to_nice_yaml used to sit in that exclusion list too,
      # but joined the dispatch itself once lazy-leaf deferral needed its
      # fail-on-access guard - see the to_nice_yaml case below.)
      KNOWN_FILTER_NAMES = Set.new(%w[
        fileglob realpath default d upper lower capitalize title trim
        strip dirname basename length count replace split sort unique
        flatten reverse join list first last min max int float string
        bool abs map select reject selectattr rejectattr to_datetime sum combine
        dict2items items2dict regex_search regex_findall regex_replace
        hash password_hash type_debug to_json b64encode b64decode
        from_json from_yaml json_query to_yaml checksum union path_join
        splitext urldecode urlsplit zip zip_longest product regex_escape
        to_nice_json to_nice_yaml human_readable human_to_bytes netmask_to_cidr md5
        sha1 expanduser expandvars normpath relpath commonpath log pow
        to_uuid symmetric_difference combinations permutations
        rekey_on_member extract from_yaml_all vault unvault ternary
        intersect difference lists_mergeby list_mergeby random map_format
        strftime
        ipaddr ipwrap ipv4 ipv6 ipsubnet ipmath next_nth_usable
        previous_nth_usable network_in_network network_in_usable
        ip4_hex
      ])

      # The pre-pass's name check: true for a name this engine's own
      # dispatch implements. The caller (ConditionalEvaluator) ORs this
      # with Crinja's own filter library, since #apply is only ever the
      # fallback path after Crinja-native filters have had their chance.
      def self.known_filter_name?(name : String) : Bool
        KNOWN_FILTER_NAMES.includes?(name)
      end

      # The compiled-regex cache itself lives in FilterCore (both
      # evaluators share it); this delegates so every existing
      # FilterEngine.cached_regex call site keeps working.
      def self.cached_regex(pattern : String, options : Regex::Options = Regex::Options::None) : Regex
        FilterCore.cached_regex(pattern, options)
      end

      # Optional variable context, needed only to resolve a `default(...)`
      # filter's argument when it's itself a variable reference rather
      # than a literal (see the "default" case in #apply below) - every
      # other filter here is a pure JSON::Any -> JSON::Any transform with
      # no variable lookups of its own.
      def initialize(@vars : Hash(String, JSON::Any)? = nil)
      end

      # The root identifier of the filter-chain head currently being
      # evaluated (set at every chain entry point, see
      # VarSubstitutor.unsafe_root?): the unsafe gate for the leaf-level
      # renders below (strict_render_deferred_leaves, map/selectattr
      # attribute extraction) - a value resolved through an
      # execution-resolved root (registered result / set_fact / fact /
      # loop item) is never re-rendered, exactly like real ansible-core's
      # AnsibleUnsafe marking. Chain argument sub-resolutions overwrite it
      # for their own (self-contained) scope; the next chain entry always
      # overwrites it before any leaf render can observe a stale value.
      @chain_root : String? = nil

      private def chain_root_unsafe? : Bool
        root = @chain_root || return false
        VarSubstitutor.resolved_var_name?(VarSubstitutor.host_from_vars(@vars), root)
      end

      # Audit pass (2026-08-11, following the ansible-vault/prometheus/
      # grafana rounds finding 5 independent copies of this exact bug):
      # re-renders *value* if its raw form is still a String containing
      # `{{` - real Ansible's recursive re-templating applied to
      # whatever a plain-lookup fallback already resolved. Now a thin
      # delegate to the ONE shared implementation
      # (VariableSubstitutor::Rerender) - the multi-span and block-tag
      # fixes this copy used to re-discover independently land there
      # once for every caller.
      private def rerender_if_templated(value : JSON::Any, source_expr : String? = nil) : JSON::Any
        Rerender.if_templated(@vars, value, source_expr) || value
      end

      # Fail-on-access guard for full-structure consumers of a filter-chain
      # head value. The chain head (ExpressionEvaluator's
      # retemplated_nested_templates with defer_unresolved) leaves a leaf
      # whose template bottoms out at an undefined name in its raw,
      # unrendered form - real Jinja2/Ansible's laziness, so a chain that
      # never reads that leaf (selectattr on a sibling field,
      # stackhpc.libvirt-vm round 952484) succeeds. A serializer like
      # to_json reads EVERY leaf by definition, though, and real Ansible
      # fails the task there ("'x' is undefined") - which is exactly what
      # this engine did before laziness landed, spec'd in
      # test/unit/nested_container_undefined_filter_test.cr. Re-running the
      # strict whole-structure render here restores that failure; it is a
      # no-op for every already-rendered container (leaves without any
      # Jinja markers pass through untouched).
      private def strict_render_deferred_leaves(value : JSON::Any) : JSON::Any
        return value unless value.raw.is_a?(Array) || value.raw.is_a?(Hash)
        return value if chain_root_unsafe?
        JinjaRenderer.rerender_nested_templates(value, VarSubstitutor.new(vars: @vars || Hash(String, JSON::Any).new))
      end

      # Splits a `|`-joined filter chain into its individual filter
      # expressions, ignoring any `|` inside a quoted string or a
      # parenthesized argument list - `replace('a|b', 'c')` is one filter,
      # not two split on the `|` inside its own argument.
      def self.split_chain(expr : String) : Array(String)
        parts = [] of String
        current = String::Builder.new
        depth = 0
        quote : Char? = nil

        expr.each_char do |char|
          if q = quote
            current << char
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
            current << char
          elsif char == '('
            depth += 1
            current << char
          elsif char == ')'
            depth -= 1
            current << char
          elsif char == '|' && depth == 0
            parts << current.to_s.strip
            current = String::Builder.new
          else
            current << char
          end
        end
        parts << current.to_s.strip
        parts.reject(&.empty?)
      end

      # Applies a `|`-joined chain of filters to *value* in order.
      def apply_chain(value : JSON::Any, chain : String) : JSON::Any
        @chain_root = VarSubstitutor.expression_root(chain)
        self.class.split_chain(chain).reduce(value) { |acc, filter_expr| apply(acc, filter_expr) }
      end
    end
  end
end
