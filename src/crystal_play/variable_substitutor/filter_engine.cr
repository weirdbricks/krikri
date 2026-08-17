require "json"
require "time"
require "yaml"
require "base64"
require "uri"
require "uuid"
require "openssl/digest"
require "../vault"
require "./variable_lookup"
require "./expression_evaluator"
require "../variable_substitutor"

module CrystalPlay
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
      # Optional variable context, needed only to resolve a `default(...)`
      # filter's argument when it's itself a variable reference rather
      # than a literal (see the "default" case in #apply below) - every
      # other filter here is a pure JSON::Any -> JSON::Any transform with
      # no variable lookups of its own.
      def initialize(@vars : Hash(String, JSON::Any)? = nil)
      end

      # Audit pass (2026-08-11, following the ansible-vault/prometheus/
      # grafana rounds finding 5 independent copies of this exact bug):
      # re-renders *value* if its raw form is still a String containing
      # `{{` - real Ansible's recursive re-templating applied to
      # whatever a plain-lookup fallback already resolved, rather than
      # duplicating the "strip one {{ }} layer and re-run through
      # ExpressionEvaluator" logic at each call site in this class.
      private def rerender_if_templated(value : JSON::Any) : JSON::Any
        vars = @vars
        return value unless vars
        return value unless (raw = value.raw).is_a?(String) && (raw.includes?("{{") || raw.includes?("{%") || raw.includes?("{#"))

        if raw.includes?("{%") || raw.includes?("{#")
          rendered = CrinjaRenderer.new(vars).render(raw)
          return (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
        end

        inner = raw.strip
        inner = inner[2..-3].strip if inner.starts_with?("{{") && inner.ends_with?("}}")
        rendered = ExpressionEvaluator.new(vars).evaluate(inner)
        (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
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
        self.class.split_chain(chain).reduce(value) { |acc, filter_expr| apply(acc, filter_expr) }
      end

      # Apply a single filter to a value.
      # Example: myvar | default('value')
      def apply(value : JSON::Any, filter_expr : String) : JSON::Any
        # `ansible.builtin.`-prefixed filter names (a real, if uncommon,
        # spelling - real Ansible's own core filters are all reachable
        # via this FQCN too, not just the bare name) never matched any
        # `case filter_name` branch below at all, silently falling to
        # the unknown-filter passthrough - found live via
        # prometheus.prometheus.prometheus's own `map('ansible.builtin.
        # fileglob') | flatten | map('ansible.builtin.realpath')` chain
        # (round 30). Stripped once here so every filter branch below
        # matches either spelling.
        filter_expr = filter_expr.lchop("ansible.builtin.") if filter_expr.starts_with?("ansible.builtin.")

        if match = filter_expr.match(/^(\w+)\s*\((.*)\)$/m)
          filter_name = match[1]
          filter_args = match[2]
        else
          filter_name = filter_expr
          filter_args = ""
        end

        case filter_name
        when "fileglob"
          # Real Ansible's ansible.builtin.fileglob LOOKUP plugin, usable
          # as a filter via `map('ansible.builtin.fileglob')` (distinct
          # from the separate `with_fileglob:` loop keyword, which
          # TaskExecutor#resolve_fileglob already handles). Real Ansible
          # returns the empty list for a pattern matching no files (not
          # an error) - without this, an unrecognized filter name fell
          # to the passthrough below, leaving the RAW glob pattern
          # string as if it were already a real, matched file path.
          JSON::Any.new(Dir.glob(as_string(value)).sort!.map { |p| JSON::Any.new(p) })
        when "realpath"
          JSON::Any.new(File.realpath(as_string(value)))
        when "default", "d"
          # "d" is Jinja2/Ansible's extremely common shorthand alias for
          # "default" (linux-system-roles uses it pervasively - 268
          # occurrences combined across just the logging and journald
          # roles: `inner_item.suffix | d('conf')`, `__rsyslog_enabled |
          # d(false)`, etc). Unrecognized before this, "d(...)" fell to
          # the unknown-filter passthrough below, silently returning the
          # *original* (often undefined) value unchanged instead of the
          # default - masked whenever the value happened to already be
          # defined (the passthrough and a real default filter agree in
          # that case), but any genuinely-undefined value stayed
          # undefined instead of getting its default, appearing as
          # "undefined"/empty text at the template-rendering layer.
          #
          # The 2-arg boolean form (`default(fallback, true)`) also needs
          # to treat any FALSY value as needing the default, not just
          # undefined/nil/empty-string (what undefined? alone catches) -
          # a real int 0 or bool false slipped through here previously.
          # Found via geerlingguy.php's own `pm.max_requests = {{
          # item.pool_pm_max_requests | default(500, true) }}`: a real
          # int 0 (meaning "unlimited" - a legitimate, deliberately-set
          # value, not a mistake) is falsy, so real Ansible replaces it
          # with 500 here; this filter previously only ever checked
          # undefined?, leaving the real int 0 in place.
          if undefined?(value) || (default_boolean_arg?(filter_args) && !truthy?(value))
            resolve_default_arg(filter_args)
          else
            value
          end
        when "upper"
          transform_string(value, &.upcase)
        when "lower"
          transform_string(value, &.downcase)
        when "capitalize"
          transform_string(value, &.capitalize)
        when "title"
          transform_string(value) { |text| text.split.map(&.capitalize).join(" ") }
        when "trim", "strip"
          transform_string(value, &.strip)
        when "dirname"
          # Real Ansible/Jinja2 filter (Python's os.path.dirname) -
          # entirely unimplemented, so it fell through to the unknown-
          # filter passthrough (returning the full path unchanged), found
          # via geerlingguy.mysql's own "Ensure error log directory
          # exists": `path: "{{ mysql_log_error | dirname }}"` with
          # `state: directory`. Left unchanged, that created a directory
          # at the *full* log-error path itself ("/var/log/mysql/
          # mysql.err") rather than its parent ("/var/log/mysql"), so
          # mysqld's own attempt to open its error log at that same path
          # found a directory instead of a file and failed to start.
          transform_string(value, &->File.dirname(String))
        when "basename"
          transform_string(value, &->File.basename(String))
        when "length", "count"
          JSON::Any.new(length_of(value).to_i64)
        when "replace"
          args = parse_filter_args(filter_args)
          transform_string(value) { |text| args.size >= 2 ? text.gsub(args[0], args[1]) : text }
        when "split"
          # Real bug found benchmarking geerlingguy.nfs (via `nfs_exports
          # | map('split') | map('first')`, applying `split` with NO
          # argument to each export line): real Python/Jinja2's
          # `str.split()` with no separator splits on any whitespace run
          # (leading/trailing whitespace ignored, no empty strings in the
          # result) - Crystal's own `String#split(delimiter)` with an
          # EMPTY STRING delimiter instead splits into individual
          # *characters*, since `parse_filter_arg("")` (no args given)
          # returned "" rather than nil. `"/path  *(opts)".split("")`
          # produced one single-char JSON::Any per character, and
          # `map('first')` on the corresponding [outer-split-then-first]
          # chain(via the map() fix immediately above) then grabbed the
          # first CHARACTER ("/") instead of the first WHITESPACE-
          # SEPARATED WORD ("/path"). Crystal's own no-arg `String#split`
          # overload (not `split("")`) already matches Python's
          # whitespace-run semantics exactly.
          parts = (filter_args.strip.empty? ? as_string(value).split : as_string(value).split(parse_filter_arg(filter_args))).map { |part| JSON::Any.new(part) }
          JSON::Any.new(parts)
        when "sort"
          JSON::Any.new(sort_json(as_array(value)))
        when "unique"
          seen = Set(String).new
          JSON::Any.new(as_array(value).select { |item| seen.add?(item.to_json) })
        when "flatten"
          # flatten(levels=none, skip_nulls=true) - real Ansible's own
          # filter (not standard Jinja2): flattens nested lists, by
          # default completely (levels=none), skipping null items by
          # default. Only implemented in Crinja's own registry before
          # (jinja_filters.cr's JinjaFilters.flatten_array), reached
          # only via `{%`/`{#` block-tag escalation - a bare `{{ }}`
          # filter-name `map('flatten')` chain (this codebase's own
          # map() reuses #apply, not Crinja) fell through to the
          # unknown-filter passthrough, returning each item completely
          # unflattened. Real bug found live-verifying prometheus.
          # prometheus.node_exporter: its own _common role's checksum-
          # file parsing (`... | map('regex_findall', ...) | map(
          # 'flatten') | map('reverse')`) needs this to collapse each
          # line's single `[[checksum, filename]]` match-list down to
          # a flat `[checksum, filename]` pair before `reverse` swaps
          # it into `[filename, checksum]` for `dict()`.
          levels = parse_kwarg(filter_args, "levels").try { |arg| resolve_expression(arg).as_i? }
          skip_nulls = parse_kwarg(filter_args, "skip_nulls").try { |arg| truthy?(resolve_expression(arg)) }
          skip_nulls = true if skip_nulls.nil?
          JSON::Any.new(flatten_array(as_array(value), levels, skip_nulls))
        when "reverse"
          case value.raw
          when Array
            JSON::Any.new(value.as_a.reverse)
          when String
            JSON::Any.new(value.as_s.reverse)
          else
            value
          end
        when "join"
          sep = filter_args.strip.empty? ? "" : parse_filter_arg(filter_args)
          JSON::Any.new(as_array(value).map { |v| as_string(v) }.join(sep))
        when "list"
          value
        when "first"
          # Real Jinja2's `first`/`last` work on any sequence, including
          # a plain string (Python treats a str as a sequence of
          # characters) - `as_array` only ever extracts a real JSON
          # array, silently returning nil/"" for a String value instead
          # of its first character. Found via konstruktoid-hardening's
          # own `... | regex_search(pattern, '\1') | first` (regex_search
          # with one backreference arg returns a plain string, matching
          # real Ansible - `first` on that string must then return its
          # first *character*, not nil).
          #
          # A genuinely empty sequence (an empty ARRAY specifically, not
          # merely "not an array at all" - `as_array` also returns `[]`
          # for an undefined/non-array value, a separate, still-deferred
          # class of gap this deliberately does NOT touch) raises here,
          # matching real Jinja2's own `do_first`: `next(iter(seq))`
          # against an empty sequence raises `StopIteration`, which
          # surfaces to a real playbook run as a hard "No first item,
          # sequence was empty." task-arg error the moment anything
          # (`.split`, `.join`, ...) touches the result. Found
          # benchmarking robertdebock.mount_options (round 140): a
          # corrupted `opts: ",nodev"` from `ansible_mounts |
          # selectattr(...) | first` on an empty match silently flowed
          # through as `nil` before this fix, failing much LATER with a
          # confusing, unrelated mount(8) error instead of failing
          # immediately with a clear message at the actual source task.
          if str = value.as_s?
            raise "No first item, sequence was empty." if str.empty?
            JSON::Any.new(str[0].to_s)
          elsif arr = value.as_a?
            raise "No first item, sequence was empty." if arr.empty?
            arr.first
          else
            JSON::Any.new(nil)
          end
        when "last"
          if str = value.as_s?
            raise "No last item, sequence was empty." if str.empty?
            JSON::Any.new(str[-1].to_s)
          elsif arr = value.as_a?
            raise "No last item, sequence was empty." if arr.empty?
            arr.last
          else
            JSON::Any.new(nil)
          end
        when "min"
          as_array(value).min_by? { |v| numeric(v) } || JSON::Any.new(nil)
        when "max"
          as_array(value).max_by? { |v| numeric(v) } || JSON::Any.new(nil)
        when "int"
          # Real Jinja2's own `int` filter (do_int) truncates a native
          # float/int directly (Python's `int(42.5) == 42`) - going
          # through #as_string first (as this used to do unconditionally)
          # turns a Float64 into its own decimal-point STRING repr
          # ("256.0"), and Crystal's strict `String#to_i64?` rejects any
          # decimal point outright, always falling to the `|| 0_i64`
          # default. `{{ 256.0 | int }}` (or ANY float, not just one
          # arriving via a division result) rendered "0" instead of
          # "256". Found via geerlingguy.swap's own check-size.yml
          # (`(stat.size / 1024 / 1024) | int`) once division itself was
          # fixed - a division result is always a float in real Jinja2,
          # so nearly every `int`-filtered division hit this. A numeric
          # string still falls through to the string-parsing path below,
          # itself widened to accept "42.5"-style decimal strings the
          # same way real Jinja2 does (int() on the string fails, falls
          # back to int(float(value))).
          case raw = value.raw
          when Int64, Int32
            JSON::Any.new(raw.to_i64)
          when Float64
            JSON::Any.new(raw.to_i64)
          when Bool
            JSON::Any.new(raw ? 1_i64 : 0_i64)
          else
            str = as_string(value)
            JSON::Any.new(str.to_i64? || str.to_f64?.try(&.to_i64) || 0_i64)
          end
        when "float"
          case raw = value.raw
          when Int64, Int32
            JSON::Any.new(raw.to_f64)
          when Float64
            JSON::Any.new(raw)
          else
            JSON::Any.new(as_string(value).to_f64? || 0.0)
          end
        when "string"
          JSON::Any.new(as_string(value))
        when "bool"
          # Real Ansible's own `bool` filter (ansible.module_utils.
          # parsing.convert_bool.boolean(), non-strict) is NOT general
          # truthiness - it matches only a fixed set of true/false
          # keywords, and returns false (not a TypeError, not the
          # string's own truthiness) for anything else. Previously
          # reused the generic #truthy? helper (correct for `when:`/
          # `{% if %}` truthiness, wrong here), so ANY non-empty,
          # non-"0"/"false" string filtered through `| bool` came out
          # true. Found via geerlingguy.gitlab's own "restart gitlab"
          # handler: `failed_when: gitlab_restart_handler_failed_when |
          # bool`, whose default value is the arbitrary expression
          # STRING `'gitlab_restart.rc != 0'` (not one of the recognized
          # keywords) - verified directly against real ansible-playbook
          # (`{{ 'gitlab_restart.rc != 0' | bool }}` renders `false`,
          # not `true`) - previously always true here, always marking
          # the handler failed regardless of the reconfigure's actual
          # exit code. Mirrors the Crinja-side `Crinja.filter(:bool)`
          # (jinja_filters.cr), which already had this right.
          case as_string(value).downcase
          when "true", "yes", "on", "1"
            JSON::Any.new(true)
          else
            JSON::Any.new(false)
          end
        when "abs"
          JSON::Any.new(numeric(value).abs)
        when "map"
          # map(attribute='x') or map('filtername', ...args) - real
          # Jinja2's map() has both forms; only attribute= was
          # implemented before. Real bug found benchmarking geerlingguy.
          # nfs's own "Ensure directories to export exist" task:
          # `nfs_exports | map('split') | map('first') | unique` (pulling
          # just the directory-path column out of each raw "/path
          # *(opts)" export line) silently no-op'd on the filter-name
          # form, leaving the WHOLE export line - options text included
          # - as the `file:` module's `path:`, creating a garbage
          # directory instead of the real export path. Recurses into
          # #apply for each item so any already-implemented filter (not
          # just split/first) works as a map() argument too -
          # parse_filter_args already strips the surrounding quotes off
          # a filter-name form's first argument ('split' -> "split"),
          # the same as any other quoted filter argument.
          #
          # The REST of the inner args (any actual filter arguments
          # beyond the filter name itself, e.g. the pattern in
          # `map('regex_findall', '^(...)$')`) must come from
          # split_top_level_args, not parse_filter_args - that one
          # preserves the original quote characters verbatim, where
          # parse_filter_args destructively strips them (needed for a
          # bare value, wrong here since inner_expr gets RE-PARSED by
          # #apply below, and an unquoted regex pattern full of its own
          # parens/`+`/`.` got misread as a bare expression instead of
          # a string literal). Real bug found live-verifying
          # prometheus.prometheus.node_exporter: `map('regex_findall',
          # '^([a-fA-F0-9]+)\\s+(.+)$')` silently became `regex_findall`
          # called with an effectively empty pattern, matching the
          # empty string at every position instead of the real
          # checksum/filename pairs.
          if attr = parse_kwarg(filter_args, "attribute")
            JSON::Any.new(as_array(value).map { |item| item.raw.is_a?(Hash) ? (item[attr]? || JSON::Any.new(nil)) : JSON::Any.new(nil) })
          elsif (inner_name = parse_filter_args(filter_args)[0]?)
            inner_args = split_top_level_args(filter_args)[1..].join(", ")
            inner_expr = inner_args.empty? ? inner_name : "#{inner_name}(#{inner_args})"
            JSON::Any.new(as_array(value).map { |item| apply(item, inner_expr) })
          else
            value
          end
        when "select"
          apply_select(value, filter_args, false)
        when "reject"
          apply_select(value, filter_args, true)
        when "selectattr"
          # selectattr('mount', 'equalto', mount.path) - dev-sec
          # os_hardening's own way of picking a single ansible_facts.mounts
          # entry out by its `mount` field, then chained into `| list |
          # first`. Only equalto/eq/ne/defined/undefined are implemented -
          # every test this codebase's roles/specs actually use - an
          # unrecognized test name falls back to a `defined` check rather
          # than silently passing every item through unfiltered.
          apply_selectattr(value, filter_args)
        when "to_datetime"
          # to_datetime('%b %d, %Y') - dev-sec os_hardening's own
          # password-ageing verification parses `chage -l`'s date output
          # this way, then subtracts two of them for a day-count assert.
          # Real Ansible's default format (no argument) is
          # '%Y-%m-%d %H:%M:%S'. Represented as a tagged JSON object
          # (epoch seconds) rather than a native type FilterEngine has no
          # concept of - ExpressionEvaluator's `-` operator (ARC:
          # combine_minus) knows to recognize and subtract two of these
          # into a timedelta, itself tagged the same way so `.days`
          # dotted access on the result works via the ordinary Hash-key
          # path.
          parse_to_datetime(value, filter_args.strip.empty? ? "%Y-%m-%d %H:%M:%S" : parse_filter_arg(filter_args))
        when "sum"
          # sum(attribute='packages', start=[]) - real Jinja2's sum()
          # filter, entirely unimplemented before (fell through to the
          # unknown-filter passthrough, returning the *selected items
          # themselves* unchanged rather than summing/concatenating
          # them). With a list-valued start:, this concatenates each
          # item's attribute value (or the item itself, with no
          # attribute=) onto start - openstack.ansible-hardening's own
          # package install/removal tasks build their final package
          # list this way (`stig_packages_rhel7 | selectattr(...) |
          # selectattr(...) | sum(attribute='packages', start=[])`).
          # With a numeric start: (real Jinja2's own default, 0), sums
          # the values/attributes as numbers instead - not needed by any
          # real usage seen so far, but a one-line addition once the
          # list-concatenation case already needs the split.
          attr = parse_kwarg(filter_args, "attribute")
          start_value = parse_kwarg_expr(filter_args, "start") || JSON::Any.new(0_i64)
          items = as_array(value).map { |item| attr ? (item[attr]? || JSON::Any.new(nil)) : item }

          if start_value.raw.is_a?(Array)
            result = start_value.as_a.dup
            items.each { |item| result.concat(as_array(item)) }
            JSON::Any.new(result)
          else
            total = numeric(start_value)
            items.each { |item| total += numeric(item) }
            JSON::Any.new(total)
          end
        when "combine"
          # combine(other1, other2, ...) - shallow dict merge, later
          # arguments win on key collisions. dev-sec os_hardening chains
          # several of these (`sysctl_config | combine(sysctl_custom_config
          # | default({})) | combine(...)`) to layer per-OS overrides on
          # top of role defaults; was previously entirely unimplemented
          # (fell through to the `else` passthrough below), silently
          # discarding every merge-in argument.
          split_top_level_args(filter_args).reduce(value) { |acc, arg_expr| combine_hash(acc, resolve_expression(arg_expr)) }
        when "dict2items"
          # dict2items(key_name='key', value_name='value') - real Ansible's
          # own filter (NOT standard Jinja2; the Crinja corpus confirms
          # Python/Jinja2 reject it as "No filter named 'dict2items'"),
          # converts a dict to a list of {key: k, value: v} items so
          # `loop: "{{ my_dict | dict2items }}"` can iterate. dev-sec
          # os_hardening's own `os_hardening_set_os_variables.yml` uses
          # exactly this shape (`with_dict` semantics) to walk a flat
          # `{mount_point: {mode: ..., owner: ...}}` config; before this
          # was implemented, the passthrough meant `FilterEngine` returned
          # the dict unchanged, `with_dict`'s loop binding produced a
          # single `item` that's the whole dict, and every downstream
          # `item.key`/`item.value` template was undefined - a regression
          # spec for the related mode bug had to be rewritten with a
          # `set_fact: my_mode: "1777"` shape to avoid the loop never
          # actually setting the fact. Now resolves to a real list of
          # `{key_name, value_name}` dicts in the same insertion order
          # Ansible's CPython 3.7+ preserves (Crystal Hash insertion
          # order is the same). The two kwarg names default to
          # `key`/`value`; os_hardening uses defaults. Real Ansible's
          # `dict2items` also accepts a `wantlist=True` form that returns
          # a list of [k, v] pairs (no dict wrapping) - not seen in any
          # role yet, deliberately not implemented.
          key_name = parse_kwarg(filter_args, "key_name") || "key"
          value_name = parse_kwarg(filter_args, "value_name") || "value"
          JSON::Any.new(dict_to_items(as_hash(value), key_name, value_name))
        when "items2dict"
          # items2dict(key_name='key', value_name='value') - the inverse
          # of dict2items: takes a list of dicts (each having a `key_name`
          # field and a `value_name` field) and produces a single dict
          # mapping key_name -> value_name. Real Ansible's own filter,
          # same Python-ansible-only status. Not yet seen in any
          # benchmarked role's playbook (the Crinja corpus has it once,
          # inside a `postgresql_global_config_options` evaluation that's
          # only reachable through `community.general`'s collection form),
          # but the corpus report classifies it as a clean
          # `[ansible-filter-only]` divergence rather than a real engine
          # bug, so implementing it here is a natural follow-up to
          # dict2items. Same kwarg API; a list element that's not a dict
          # or is missing the key_name field is silently skipped (the
          # inverse: a partial dict would otherwise crash the whole
          # filter on a single malformed element).
          key_name = parse_kwarg(filter_args, "key_name") || "key"
          value_name = parse_kwarg(filter_args, "value_name") || "value"
          JSON::Any.new(items_to_dict(as_array(value), key_name, value_name))
        when "regex_search"
          # regex_search(pattern, group_ref='') - real Ansible's own
          # filter (not standard Jinja2): searches *pattern* anywhere in
          # value (Python re.search, not a full match), and with a
          # backreference-style second argument (`'\\1'`) returns that
          # captured group's text instead of the whole match. No match
          # at all resolves to "undefined" (matching the general
          # unresolved-lookup convention elsewhere in this evaluator),
          # not an empty string, so a caller chaining `| first` (real
          # Ansible would get `None` back and typically guards with
          # `default(...)`) doesn't silently succeed on bogus data.
          # Found via konstruktoid-hardening's own `sshd_version.
          # stderr_lines | regex_search('OpenSSH_(...)', '\\1') | first`
          # (extracting the installed OpenSSH version) - previously
          # unimplemented and falling through to the `else` passthrough
          # below, returning `sshd_version.stderr_lines` *itself*
          # unfiltered as "the version", which downstream `is
          # version(...)` comparisons then read nonsense out of.
          args = split_top_level_args(filter_args)
          pattern = args[0]?.try { |arg| as_string(resolve_expression(arg)) } || ""
          group_ref = args[1]?.try { |arg| as_string(resolve_expression(arg)) }

          if match = as_string(value).match(Regex.new(pattern))
            if group_ref
              JSON::Any.new(group_ref.gsub(/\\(\d)/) { match[$1.to_i]? || "" })
            else
              JSON::Any.new(match[0])
            end
          else
            JSON::Any.new("undefined")
          end
        when "regex_findall"
          # regex_findall(pattern, multiline=False, ignorecase=False) -
          # real Ansible's own filter (Python re.findall): every non-
          # overlapping match. No capture groups -> each match is the
          # whole matched substring; with capture groups -> each match
          # is a list of that match's group strings. Same shape as the
          # Crinja-side `Crinja.filter(:regex_findall)` (jinja_filters.
          # cr) - needed here too since a bare `{{ }}` filter-name
          # `map('regex_findall', ...)` chain goes through THIS plain
          # evaluator, not Crinja (only `{%`/`{#` block-tag escalation
          # reaches Crinja's filters). Real bug found live-verifying
          # prometheus.prometheus.node_exporter: its own _common role's
          # checksum-file parsing (`raw.splitlines() | map('regex_
          # findall', '^([a-fA-F0-9]+)\\s+(.+)$') | ...`) silently no-
          # op'd (each line passed through unchanged instead of being
          # split into [checksum, filename]) - the whole checksum dict
          # ended up empty, failing every download's checksum check.
          args = split_top_level_args(filter_args)
          pattern = args[0]?.try { |arg| as_string(resolve_expression(arg)) } || ""
          options = Regex::Options::None
          options |= Regex::Options::MULTILINE if args[1]?.try { |arg| truthy?(resolve_expression(arg)) }
          options |= Regex::Options::IGNORE_CASE if args[2]?.try { |arg| truthy?(resolve_expression(arg)) }
          regex = Regex.new(pattern, options)

          matches = as_string(value).scan(regex).map do |match|
            if match.size > 1
              JSON::Any.new((1...match.size).map { |i| JSON::Any.new(match[i]? || "") })
            else
              JSON::Any.new(match[0])
            end
          end
          JSON::Any.new(matches)
        when "regex_replace"
          # regex_replace(pattern, replacement='') - real Ansible's own
          # filter: replaces every match of *pattern* in value with
          # *replacement* (Python re.sub, not just the first match),
          # backreferences (`\1`) in replacement substituted from the
          # matched capture groups. Entirely missing from this plain
          # `{{ }}` evaluator (Crinja's own pipeline, used only for
          # `{%`/`{#` block-tag escalation, already had one) - fell
          # through to the unknown-filter passthrough, returning value
          # completely unchanged. Found via geerlingguy.node_exporter's
          # own `_github_release.json.tag_name | regex_replace('^v?
          # ([0-9\.]+)$', '\1')` (stripping a GitHub release tag's
          # leading "v", e.g. "v1.12.1" -> "1.12.1") - the still-"v"-
          # prefixed version then built a download URL with a doubled
          # "v" ("vv1.12.1"), which doesn't exist as a real release.
          args = split_top_level_args(filter_args)
          pattern = args[0]?.try { |arg| as_string(resolve_expression(arg)) } || ""
          replacement = args[1]?.try { |arg| as_string(resolve_expression(arg)) } || ""

          result = as_string(value).gsub(Regex.new(pattern)) do |_, match|
            replacement.gsub(/\\(\d)/) { match[$1.to_i]? || "" }
          end
          JSON::Any.new(result)
        when "hash"
          # hash(algorithm='sha1') - real Ansible's own filter
          # (ansible.plugins.filter.core), wrapping Python's
          # `hashlib.new()`. Defaults to sha1 when no argument is given.
          # Mirrors the Crinja-side copy added for the same gap found via
          # geerlingguy.supervisor's own supervisord.conf.j2 (a `.j2`
          # template file, reaching Crinja not this evaluator) - added
          # here too on the usual "check both evaluators" rule, since a
          # bare `{{ x | hash('sha256') }}` task param would only ever
          # reach this one.
          args = split_top_level_args(filter_args)
          algorithm = (args[0]?.try { |arg| as_string(resolve_expression(arg)) } || "sha1").downcase
          openssl_name = case algorithm
                         when "md5"    then "MD5"
                         when "sha1"   then "SHA1"
                         when "sha224" then "SHA224"
                         when "sha256" then "SHA256"
                         when "sha384" then "SHA384"
                         when "sha512" then "SHA512"
                         else
                           raise "hash: unsupported algorithm '#{algorithm}'"
                         end
          digest = OpenSSL::Digest.new(openssl_name)
          digest.update(as_string(value))
          JSON::Any.new(digest.final.hexstring)
        when "password_hash"
          # password_hash(hashtype='sha512', salt=None, rounds=None) -
          # real Ansible's own filter (passlib-backed), a salted crypt(3)
          # hash suitable for /etc/shadow, NOT a plain digest like
          # `hash` above. Entirely unimplemented - a `password: "{{
          # plaintext | password_hash('sha512') }}"` (the standard way
          # any role sets a user's password, e.g. robertdebock.users)
          # silently passed the plaintext string straight through
          # unfiltered, landing verbatim in /etc/shadow. Covers the
          # three crypt(3) schemes `openssl passwd` itself supports
          # (sha512/sha256/md5, matching /etc/shadow's own $6$/$5$/$1$)
          # - passlib-only schemes like bcrypt aren't available without
          # a real passlib port, same scope limit already documented for
          # the htpasswd plugin's own crypt_scheme handling.
          args = split_top_level_args(filter_args)
          hashtype = (args[0]?.try { |arg| as_string(resolve_expression(arg)) } || "sha512").downcase
          openssl_flag = case hashtype
                         when "md5"    then "-1"
                         when "sha256" then "-5"
                         when "sha512" then "-6"
                         else
                           raise "password_hash: unsupported hashtype '#{hashtype}' (supported: md5, sha256, sha512)"
                         end
          explicit_salt = args[1]?.try { |arg| as_string(resolve_expression(arg)) }
          salt = explicit_salt.presence || Random::Secure.hex(8)

          output = IO::Memory.new
          status = Process.run("openssl", ["passwd", openssl_flag, "-salt", salt, "-stdin"],
            input: IO::Memory.new(as_string(value)), output: output)
          raise "password_hash: openssl passwd failed" unless status.success?
          JSON::Any.new(output.to_s.strip)
        when "type_debug"
          # type_debug - real Ansible/Jinja2's own filter, returns
          # Python's type name for the value (matching `type(x).
          # __name__`) - used almost exclusively in role assert.yml
          # sanity checks (`my_list | type_debug == "list"`). Entirely
          # unimplemented - fell through to the unknown-filter
          # passthrough, returning the value's own rendered string
          # instead of a type name, so every one of these asserts failed
          # outright regardless of the actual (correct) variable type.
          # Found via robertdebock.httpd's own assert.yml (round 19).
          type_name = case value.raw
                      when Array  then "list"
                      when Hash   then "dict"
                      when String then "str"
                      when Int64  then "int"
                      when Float64 then "float"
                      when Bool   then "bool"
                      when Nil    then "NoneType"
                      else "str"
                      end
          JSON::Any.new(type_name)
        when "to_json"
          # to_json(**kwargs) - real Ansible's own filter, wraps Python's
          # json.dumps() (default ", "/": " item/key separators, not
          # Crystal's own compact JSON::Any#to_json) - added here too on
          # the usual "check both evaluators" rule, matching the Crinja-
          # side copy added for the same gap found via geerlingguy.
          # logstash's own 30-elasticsearch-output.conf.j2 (a `.j2`
          # template file, reaching Crinja not this evaluator).
          JSON::Any.new(python_json_dump(value))
        when "b64encode"
          # b64encode(encoding='utf-8') - real Ansible's own filter,
          # standard base64 (not urlsafe). Entirely unimplemented before
          # - a bare `{{ }}` task param using it (as opposed to the same
          # filter reaching Crinja via a `.j2` file, already registered
          # separately in jinja_filters.cr) fell through to the
          # unknown-filter passthrough, silently returning the plaintext
          # value unencoded.
          JSON::Any.new(Base64.strict_encode(as_string(value)))
        when "b64decode"
          # b64decode() - inverse of the above. Real Ansible raises on
          # invalid input rather than silently passing it through;
          # matched here via Base64's own DecodeError.
          begin
            JSON::Any.new(Base64.decode_string(as_string(value)))
          rescue
            raise "b64decode: invalid base64 input"
          end
        when "from_json"
          # from_json() - real Ansible's own filter, parses a JSON
          # string value into a real structure (the mirror of to_json
          # above) - commonly used on a registered command/uri result's
          # own stdout/content ("{{ result.stdout | from_json }}").
          begin
            JSON.parse(as_string(value))
          rescue
            raise "from_json: invalid JSON input"
          end
        when "from_yaml"
          # from_yaml() - real Ansible's own filter, parses a YAML
          # string into a real structure. Converts via YAML.parse ->
          # to_json -> JSON.parse (YAML's Any and JSON::Any aren't the
          # same type in Crystal) rather than hand-rolling a converter.
          begin
            JSON.parse(YAML.parse(as_string(value)).to_json)
          rescue
            raise "from_yaml: invalid YAML input"
          end
        when "to_yaml"
          # to_yaml(**kwargs) - real Ansible's own filter, a YAML dump
          # (real PyYAML default: block style, keys sorted). Converts
          # via value.to_json -> YAML.parse -> to_yaml (JSON is a valid
          # YAML flow-syntax subset, round-trips cleanly through
          # Crystal's own YAML formatter) - same approach the Crinja-
          # side to_nice_yaml filter already uses, mirrored here for the
          # plain `{{ }}` evaluator. Unlike to_nice_yaml, doesn't accept
          # indent=/sort_keys= overrides - matches real Ansible, where
          # to_yaml (unlike to_nice_yaml) takes no such kwargs of its
          # own beyond the underlying yaml.dump()'s already-implied
          # defaults.
          JSON::Any.new(YAML.parse(value.to_json).to_yaml)
        when "checksum"
          # checksum() - real Ansible's own filter (ansible.plugins.
          # filter.core), a plain sha1 hex digest - distinct from the
          # general-purpose `hash(algorithm=...)` filter above (which
          # defaults to sha1 too, but accepts other algorithms);
          # checksum specifically always means sha1, matching Ansible's
          # own hard-coded `hashlib.sha1(...)`.
          digest = OpenSSL::Digest.new("SHA1")
          digest.update(as_string(value))
          JSON::Any.new(digest.final.hexstring)
        when "union"
          # union(other) - real Ansible's own filter, set union
          # preserving first-seen order (matches Ansible's own
          # `_unique_dedupe` list dedup approach, not naive
          # concatenation - a duplicate that appears within one of the
          # two source lists is also collapsed, not just cross-list
          # duplicates). Like intersect/difference above, `other` is
          # expected to be a variable reference - resolve_base_expression
          # has no `[...]` list-literal parser (only `{...}` dict
          # literals), a pre-existing gap shared by every filter here
          # that takes another list as its argument, not specific to
          # union.
          other = resolve_expression(filter_args)
          left = value.as_a? || [] of JSON::Any
          right = other.as_a? || [] of JSON::Any
          combined = (left + right).uniq { |item| item.to_json }
          JSON::Any.new(combined)
        when "path_join"
          # path_join(list) - real Ansible filter: joins a list of path
          # components with os.path.join semantics (an absolute
          # component resets the accumulated path rather than appending
          # to it - Crystal's own File.join has no such reset).
          parts = as_array(value).map(&.as_s?).compact
          joined = parts.reduce("") { |acc, part| part.starts_with?('/') ? part : File.join(acc, part) }
          JSON::Any.new(joined)
        when "splitext"
          # splitext() - real Ansible filter, mirrors Python's
          # os.path.splitext: [root, ext] (ext includes the leading '.',
          # empty string if there's no extension).
          str = as_string(value)
          ext = File.extname(str)
          root = ext.empty? ? str : str[0, str.size - ext.size]
          JSON::Any.new([JSON::Any.new(root), JSON::Any.new(ext)])
        when "urldecode"
          # urldecode() - real Ansible filter, percent-decodes a URL-
          # encoded string.
          JSON::Any.new(URI.decode(as_string(value)))
        when "urlsplit"
          # urlsplit(query='') - real Ansible filter: parses value as a
          # URL. With no argument, returns the full breakdown dict; with
          # a component name argument, returns just that component as a
          # string (empty string if absent) - matches real Ansible's own
          # urlsplit.py exactly (query= is the positional arg name
          # despite selecting any component, not just the querystring).
          uri = URI.parse(as_string(value)) rescue nil
          return JSON::Any.new(nil) unless uri
          args = split_top_level_args(filter_args)
          component = args[0]?.try { |arg| as_string(resolve_expression(arg)) }
          fragment = uri.fragment || ""
          full = {
            "scheme"   => uri.scheme || "",
            "netloc"   => (uri.host ? "#{uri.host}#{uri.port ? ":#{uri.port}" : ""}" : ""),
            "hostname" => uri.host || "",
            "port"     => uri.port ? uri.port.to_s : "",
            "path"     => uri.path || "",
            "query"    => uri.query || "",
            "fragment" => fragment,
            "username" => uri.user || "",
            "password" => uri.password || "",
          }
          if component
            JSON::Any.new(full[component]? || "")
          else
            JSON::Any.new(full.transform_values { |v| JSON::Any.new(v) })
          end
        when "zip", "zip_longest"
          # zip(*others)/zip_longest(*others, fillvalue=None) - real
          # Ansible filters, Python's own zip()/itertools.zip_longest().
          longest = filter_name == "zip_longest"
          lists = [as_array(value)] + split_top_level_args(filter_args).reject { |a| a.strip.starts_with?("fillvalue") }.map { |arg| as_array(resolve_expression(arg)) }
          fillvalue = parse_kwarg_expr(filter_args, "fillvalue") || JSON::Any.new(nil)
          size = longest ? (lists.map(&.size).max? || 0) : (lists.map(&.size).min? || 0)
          rows = (0...size).map do |i|
            JSON::Any.new(lists.map { |list| list[i]? || fillvalue })
          end
          JSON::Any.new(rows)
        when "product"
          # product(*others) - real Ansible filter, Python's own
          # itertools.product(): Cartesian product of value and every
          # other list argument, each result row a list.
          lists = [as_array(value)] + split_top_level_args(filter_args).map { |arg| as_array(resolve_expression(arg)) }
          result = lists.reduce([[] of JSON::Any]) do |acc, list|
            acc.flat_map { |row| list.map { |item| row + [item] } }
          end
          JSON::Any.new(result.map { |row| JSON::Any.new(row) })
        when "regex_escape"
          # regex_escape(re_type='python') - real Ansible filter, escapes
          # regex special characters so the value can be embedded
          # literally into a larger pattern.
          JSON::Any.new(Regex.escape(as_string(value)))
        when "to_nice_json"
          # to_nice_json(indent=4, sort_keys=True) - real Ansible filter,
          # a pretty-printed JSON dump (the mirror of to_nice_yaml).
          # Crystal's own JSON::Any#to_pretty_json (2-space indent) is
          # used rather than hand-rolling a 4-space emitter - narrower
          # than real Ansible's exact byte output but structurally
          # correct, same scope limit to_nice_yaml's own indent= already
          # documents.
          sort_keys = (kw = parse_kwarg_expr(filter_args, "sort_keys")) ? truthy?(kw) : true
          sorted = sort_keys ? sort_json_keys(value) : value
          JSON::Any.new(sorted.to_pretty_json)
        when "human_readable"
          # human_readable(isbits=False, unit=None) - real Ansible
          # filter, formats a byte count as e.g. "1.00 KB" (1024-based).
          bytes = value.as_i64? || value.as_f?.try(&.to_i64) || 0_i64
          isbits = (kw = parse_kwarg_expr(filter_args, "isbits")) ? truthy?(kw) : false
          JSON::Any.new(format_human_readable(bytes, isbits))
        when "human_to_bytes"
          # human_to_bytes(default_unit=None, isbits=False) - real
          # Ansible filter, the inverse of human_readable: parses
          # "10GB"/"1.5 MB" etc back into a raw byte count.
          JSON::Any.new(parse_human_to_bytes(as_string(value)))
        when "md5"
          digest = OpenSSL::Digest.new("MD5")
          digest.update(as_string(value))
          JSON::Any.new(digest.final.hexstring)
        when "sha1"
          digest = OpenSSL::Digest.new("SHA1")
          digest.update(as_string(value))
          JSON::Any.new(digest.final.hexstring)
        when "expanduser"
          # expanduser() - real Ansible filter, mirrors Python's
          # os.path.expanduser: a leading `~` (or `~user`, not
          # supported here - only the current-user shorthand) expands
          # to $HOME.
          str = as_string(value)
          home = ENV["HOME"]? || ""
          JSON::Any.new(str.starts_with?("~/") ? File.join(home, str[2..]) : (str == "~" ? home : str))
        when "expandvars"
          # expandvars() - real Ansible filter, mirrors Python's
          # os.path.expandvars: `$VAR`/`${VAR}` references replaced from
          # the CONTROLLER's own environment (unset -> left as-is,
          # matching Python's own behavior).
          str = as_string(value)
          expanded = str.gsub(/\$\{(\w+)\}|\$(\w+)/) do |match|
            name = $1? || $2?
            name ? (ENV[name]? || match) : match
          end
          JSON::Any.new(expanded)
        when "normpath"
          # normpath() - real Ansible filter, mirrors Python's
          # os.path.normpath: collapses `.`/`..`/redundant `/` without
          # making the path absolute (relative stays relative).
          JSON::Any.new(normalize_path(as_string(value)))
        when "relpath"
          # relpath(start='.') - real Ansible filter, mirrors Python's
          # os.path.relpath: value expressed relative to *start*.
          args = split_top_level_args(filter_args)
          start = args[0]?.try { |arg| as_string(resolve_expression(arg)) } || "."
          JSON::Any.new(Path[as_string(value)].relative_to(Path[start]).to_s)
        when "commonpath"
          # commonpath() - real Ansible filter, mirrors Python's
          # os.path.commonpath: the longest common directory prefix of
          # value (a list of paths).
          paths = as_array(value).map(&.as_s?).compact
          JSON::Any.new(common_path(paths))
        when "log"
          # log(base=math.e) - real Ansible filter: natural log with no
          # argument, log base *base* otherwise.
          args = split_top_level_args(filter_args)
          base = args[0]?.try { |arg| as_string(resolve_expression(arg)).to_f? }
          num = value.as_f? || value.as_i64?.try(&.to_f) || 0.0
          result = base ? Math.log(num, base) : Math.log(num)
          JSON::Any.new(result)
        when "pow"
          # pow(x) - real Ansible filter: value raised to the power x.
          args = split_top_level_args(filter_args)
          exponent = args[0]?.try { |arg| as_string(resolve_expression(arg)).to_f? } || 0.0
          num = value.as_f? || value.as_i64?.try(&.to_f) || 0.0
          JSON::Any.new(num ** exponent)
        when "to_uuid"
          # to_uuid(namespace=ANSIBLE_NAMESPACE) - real Ansible filter, a
          # deterministic UUID5 (SHA1-based) - same input always
          # produces the same UUID. Ansible's own default namespace
          # ('361E6D51-FAEC-444A-9079-341386DA8E2E'), not the standard
          # DNS namespace real uuid5() implementations default to.
          JSON::Any.new(UUID.v5(as_string(value), UUID.new("361E6D51-FAEC-444A-9079-341386DA8E2E")).to_s)
        when "symmetric_difference"
          # symmetric_difference(other) - real Ansible filter: elements
          # in exactly one of value/other, not both.
          other = resolve_expression(filter_args)
          left = (value.as_a? || [] of JSON::Any).uniq { |i| i.to_json }
          right = (other.as_a? || [] of JSON::Any).uniq { |i| i.to_json }
          result = (left.reject { |i| right.any? { |r| r.to_json == i.to_json } }) +
                   (right.reject { |i| left.any? { |l| l.to_json == i.to_json } })
          JSON::Any.new(result)
        when "combinations"
          # combinations(n) - real Ansible filter, Python's own
          # itertools.combinations(value, n): every n-length combination
          # (order-independent, no repeats) of value's own elements.
          args = split_top_level_args(filter_args)
          n = args[0]?.try { |arg| as_string(resolve_expression(arg)).to_i? } || 2
          JSON::Any.new(combinations(as_array(value), n).map { |c| JSON::Any.new(c) })
        when "permutations"
          # permutations(n=None) - real Ansible filter, Python's own
          # itertools.permutations(value, n): every n-length ordered
          # arrangement (defaults to the full length of value).
          args = split_top_level_args(filter_args)
          arr = as_array(value)
          n = args[0]?.try { |arg| as_string(resolve_expression(arg)).to_i? } || arr.size
          JSON::Any.new(permutations(arr, n).map { |p| JSON::Any.new(p) })
        when "rekey_on_member"
          # rekey_on_member(member, duplicates='error') - real Ansible
          # filter: converts a list of dicts into a dict keyed by each
          # element's own `member` field value. `duplicates:` real
          # options are error/overwrite/warn - `warn` isn't meaningfully
          # different from `overwrite` in a non-interactive engine with
          # no separate warning channel here, so both just overwrite;
          # only the default `error` genuinely raises.
          args = split_top_level_args(filter_args)
          member = args[0]?.try { |arg| as_string(resolve_expression(arg)) } || ""
          duplicates = args[1]?.try { |arg| as_string(resolve_expression(arg)) } || "error"
          result = Hash(String, JSON::Any).new
          as_array(value).each do |item|
            key = item.as_h?.try(&.[member]?).try(&.as_s?)
            next unless key
            if duplicates == "error" && result.has_key?(key)
              raise "rekey_on_member: duplicate key '#{key}'"
            end
            result[key] = item
          end
          JSON::Any.new(result)
        when "extract"
          # extract(container, morekeys=None) - real Ansible filter:
          # value is used as an index/key into *container* (commonly
          # piped from `map('extract', container)` over a list of
          # indices/keys); `morekeys` (a further key, or list of keys)
          # drills down into the extracted element.
          args = split_top_level_args(filter_args)
          container = args[0]?.try { |arg| resolve_expression(arg) }
          return JSON::Any.new(nil) unless container

          extracted = case raw = container.raw
                      when Array
                        idx = value.as_i64?.try(&.to_i)
                        idx ? raw[idx]? : nil
                      when Hash
                        raw[as_string(value)]?
                      end
          return JSON::Any.new(nil) unless extracted

          if morekeys_arg = args[1]?
            morekeys = resolve_expression(morekeys_arg)
            keys = morekeys.as_a? ? morekeys.as_a.map { |k| as_string(k) } : [as_string(morekeys)]
            keys.reduce(extracted) { |acc, key| acc.as_h?.try(&.[key]?) || JSON::Any.new(nil) }
          else
            extracted
          end
        when "from_yaml_all"
          # from_yaml_all() - real Ansible filter: parses a multi-
          # document YAML string (`---`-separated) into a list of
          # parsed documents.
          begin
            docs = as_string(value).split(/^---\s*$/m).map(&.strip).reject(&.empty?)
            JSON::Any.new(docs.map { |doc| JSON.parse(YAML.parse(doc).to_json) })
          rescue
            raise "from_yaml_all: invalid YAML input"
          end
        when "vault"
          # vault(secret, vault_id=None, salt=None) - real Ansible
          # filter: encrypts value into ansible-vault ciphertext text
          # using *secret* as the vault password (an explicit filter
          # argument, NOT the session-wide --vault-password-file/
          # --ask-vault-pass secret Vault.password holds - real
          # Ansible's own vault filter takes its own key this way too).
          args = split_top_level_args(filter_args)
          secret = args[0]?.try { |arg| as_string(resolve_expression(arg)) } || ""
          JSON::Any.new(Vault.encrypt(as_string(value), secret))
        when "unvault"
          # unvault(secret) - real Ansible filter, the inverse of vault
          # above: decrypts an ansible-vault ciphertext string using
          # *secret* as the password.
          args = split_top_level_args(filter_args)
          secret = args[0]?.try { |arg| as_string(resolve_expression(arg)) } || ""
          JSON::Any.new(Vault.decrypt(as_string(value), secret))
        when "ternary"
          # ternary(true_val, false_val) - real Ansible's own filter
          # (ansible.builtin, not standard Jinja2): `true_val` if value
          # is truthy, else `false_val`. Was entirely unimplemented in
          # this plain `{{ }}` evaluator (only the separate Crinja
          # pipeline used for `{% %}` template files had one) - fell
          # through to the `else` passthrough, returning *value itself*
          # unfiltered instead of either branch. Found via linux-system-
          # roles' journald role: `(is_ostree | d(false)) | ternary(
          # 'ansible.posix.rhel_rpm_ostree', omit)` as a module param
          # value (not inside a template), which only ever reaches this
          # evaluator, never Crinja's.
          args = split_top_level_args(filter_args)
          chosen = (truthy?(value) ? args[0]? : args[1]?).try(&.strip) || ""

          if chosen == "omit"
            JSON::Any.new(OMIT_SENTINEL)
          elsif quoted_literal?(chosen)
            JSON::Any.new(unescape_string_literal(chosen[1..-2]))
          else
            resolve_expression(chosen)
          end
        when "intersect"
          # intersect(other) - real Ansible's own filter (ansible.builtin,
          # not standard Jinja2): elements of *value* that also appear in
          # *other*, deduplicated, order taken from *value*. Was
          # previously unimplemented (fell through to the `else`
          # passthrough below, returning the *unfiltered* left-hand list)
          # - found via konstruktoid-hardening's own `ansible_facts.
          # packages.keys() | intersect(packages_blocklist)` (computing
          # which of a ~25-item denylist are actually installed): with no
          # filtering at all, that expression evaluated to literally every
          # installed package (600+), turning the next task's "remove
          # each blocklisted package" loop into "attempt to
          # apt-get-remove every installed package one at a time" -
          # correctness bug and a multi-hour hang, not just wrong data.
          other = as_array(resolve_expression(filter_args)).to_set
          JSON::Any.new(as_array(value).uniq.select { |item| other.includes?(item) })
        when "difference"
          # difference(other) - real Ansible's own filter: elements of
          # *value* that do NOT appear in *other*, deduplicated, order
          # taken from *value*. Like intersect above, this fell through to
          # the unfiltered passthrough below (returning *value* itself
          # unchanged) - found via linux-system-roles/journald's `when:
          # __journald_required_facts | difference(ansible_facts.keys() |
          # list) | length > 0` gate around a `setup:` re-gather task: with
          # no filtering, the "still-needed facts" list was always the
          # full required-facts list regardless of what was already
          # gathered, so the guard never skipped - a redundant `setup:` re-
          # run every time instead of a correctness bug on its own, but a
          # PLAY RECAP divergence (task counted as "ok" instead of
          # "skipped") that would recur in any role using this common
          # required-facts guard pattern.
          other_set = as_array(resolve_expression(filter_args)).to_set
          JSON::Any.new(as_array(value).uniq.reject { |item| other_set.includes?(item) })
        else
          # Unknown filter - return value as-is (matches prior behavior)
          value
        end
      end

      DATETIME_TAG    = "__crystal_datetime__"
      TIMEDELTA_TAG   = "__crystal_timedelta__"

      private def parse_to_datetime(value : JSON::Any, format : String) : JSON::Any
        time = Time.parse(as_string(value), format, Time::Location::UTC) rescue nil
        return JSON::Any.new(nil) unless time
        JSON::Any.new({DATETIME_TAG => JSON::Any.new(time.to_unix.to_i64)})
      end

      private def undefined?(value : JSON::Any) : Bool
        case value.raw
        when Nil
          true
        when String
          # Empty string, and also this evaluator's own internal sentinel
          # for "lookup failed" (see VariableLookup#resolve_indexed and
          # many other call sites throughout expression_evaluator.cr) -
          # every one of them renders an unresolved value as the literal
          # text "undefined" rather than a real Undefined type, so a
          # chained dict lookup that misses (`_bootstrap_packages[key] |
          # default(...)`) must treat that literal text the same as a
          # true miss. Found via robertdebock.bootstrap's own
          # `_bootstrap_packages[bootstrap_distribution ~'_'~
          # bootstrap_distribution_major_version] | default(...) |
          # default(...)` (round 18): "Ubuntu_22" isn't a real key, so the
          # first indexing missed and rendered "undefined" - a non-empty
          # string previously - so `default()` never replaced it and the
          # whole chain resolved to the literal package name "undefined",
          # which then failed to install.
          value.as_s.empty? || value.as_s == "undefined"
        else
          false
        end
      end

      # `default(fallback)` or `default(fallback, boolean)` - real Jinja2's
      # second (boolean) form, used by dev-sec os_hardening's own
      # `mount.src | default(mountinfo.device, true)` to also treat an
      # empty string as needing the default (undefined? below already does
      # that unconditionally, so the boolean itself doesn't need reading -
      # its only job here is making sure it isn't swallowed into the first
      # argument's own text). Splits on the top-level comma first, THEN
      # resolves just the first argument - previously the whole
      # "mountinfo.device, true" string (comma and all) was handed
      # straight to parse_filter_arg, which had no notion of a second
      # argument and returned that entire literal text as the "default"
      # value instead of resolving `mountinfo.device` as the variable
      # reference it is.
      # Whether `default(...)`'s optional second (boolean) argument is
      # present and true - a bare `true` literal, the only spelling real
      # roles use for this filter's own boolean arg (unlike a general
      # expression, which could also be a variable reference, but no
      # real usage seen so far needs that).
      private def default_boolean_arg?(args : String) : Bool
        split_top_level_args(args)[1]?.try(&.strip) == "true"
      end

      private def resolve_default_arg(args : String) : JSON::Any
        first_arg = split_top_level_args(args).first? || ""

        # `default(omit)` - real Ansible's magic variable that drops the
        # *parameter itself* from the module call rather than substituting
        # any real value (konstruktoid-hardening's "Allow outgoing
        # specified ports" task uses `proto: "{{ item.proto | default(omit)
        # }}"` to skip proto for loop items that don't specify one). `omit`
        # is a bare, unquoted identifier here - not a variable lookup - so
        # it's special-cased before falling into #resolve_expression, which
        # would otherwise treat it as an ordinary (undefined) variable
        # reference. See CrystalPlay::OMIT_SENTINEL for where this value is
        # consumed (#substitute_task_params strips the whole param).
        return JSON::Any.new(OMIT_SENTINEL) if first_arg.strip == "omit"

        # A default value that's itself a `+`-concatenation of parenthesized
        # ternaries/filter chains (linux-system-roles/logging's rsyslog
        # subrole computing a config filename: `inner_item.filename | d(
        # (weight_expr) + "-" + (name_expr) + "." + (suffix_expr))`) is
        # beyond what resolve_expression below understands - it only ever
        # splits a ternary or a `|` filter chain, with no concept of a
        # top-level `+`/`-`/leading-paren operator chain. Delegating to the
        # full ExpressionEvaluator (which already handles all of that, and
        # gives identical results for the plain ternary-or-filter-chain
        # cases resolve_expression already covers) fixes the complex case
        # without touching every other resolve_expression caller.
        if top_level_plus_or_minus?(first_arg)
          rendered = ExpressionEvaluator.new(@vars || Hash(String, JSON::Any).new).evaluate(first_arg)
          return (JSON.parse(rendered) rescue JSON::Any.new(rendered))
        end

        resolve_expression(first_arg)
      end

      # select(test, *args) / reject(test, *args) - real Jinja2's own
      # filters, testing each bare LIST ELEMENT directly against a named
      # test (as opposed to selectattr/rejectattr, which test a dict
      # element's given attribute). Entirely unimplemented - neither
      # filter name was recognized at all, so both fell through to the
      # unknown-filter passthrough, silently returning the list
      # unchanged regardless of the test. Found via prometheus.
      # prometheus._common's own preflight.yml: `[_common_web_listen_
      # address] | flatten | reject('match', '.+:\d+$') | list | length
      # == 0` (asserting the listen address is host:port shaped, not
      # bare-port) - reject's passthrough meant the list was never
      # actually filtered, so the assert failed regardless of whether
      # the address was valid.
      private def apply_select(value : JSON::Any, args : String, invert : Bool) : JSON::Any
        parts = split_top_level_args(args)
        test = parts[0]?.try { |part| resolve_default_expression(part) }.try(&.as_s?) || "truthy"
        compare_value = parts[1]?.try { |part| resolve_default_expression(part) }

        filtered = as_array(value).select { |item| item_matches_test?(item, test, compare_value) != invert }
        JSON::Any.new(filtered)
      end

      private def item_matches_test?(item : JSON::Any, test : String, compare_value : JSON::Any?) : Bool
        case test
        when "match", "search"
          str = item.as_s?
          pattern = compare_value.try(&.as_s?)
          return false unless str && pattern
          regex = Regex.new(test == "match" ? "^(?:#{pattern})" : pattern)
          !!(str =~ regex)
        when "in"
          compare_value.try(&.raw.as?(Array)).try(&.includes?(item)) || false
        when "truthy"
          # select()/reject() with no test name given at all defaults to
          # real Jinja2's own bare truthiness check on the item itself
          # (`select()` alone = "keep every truthy item") - distinct
          # from selectattr's own default ("defined"), since select
          # operates on the item's actual value, not an attribute
          # presence check.
          truthy?(item)
        else
          selectattr_matches?(JSON::Any.new({"_item" => item} of String => JSON::Any), "_item", test, compare_value)
        end
      end

      private def apply_selectattr(value : JSON::Any, args : String) : JSON::Any
        parts = split_top_level_args(args)
        attr = parts[0]?.try { |part| resolve_default_expression(part) }.try(&.as_s?)
        return value unless attr

        test = parts[1]?.try { |part| resolve_default_expression(part) }.try(&.as_s?) || "defined"
        compare_value = parts[2]?.try { |part| resolve_default_expression(part) }

        filtered = as_array(value).select { |item| selectattr_matches?(item, attr, test, compare_value) }
        JSON::Any.new(filtered)
      end

      private def selectattr_matches?(item : JSON::Any, attr : String, test : String, compare_value : JSON::Any?) : Bool
        attr_value = item.raw.is_a?(Hash) ? item[attr]? : nil

        # A dict-list entry's own attribute can itself be an unrendered
        # template string - openstack.ansible-hardening's own
        # `stig_packages_rhel7` list gives every entry's `state:` as
        # `"{{ security_package_state }}"` rather than a literal
        # "present"/"absent", relying on real Ansible's usual recursive
        # value re-templating. Comparing that raw, still-`{{ }}`-bearing
        # text against a real "present"/"absent" compare_value never
        # matched, so `selectattr('state', 'equalto', item)` (picking
        # which packages to install/remove per computed state) always
        # excluded every such entry - chrony (gated exactly this way)
        # was silently never installed, only surfacing much later as an
        # unrelated-looking "Unit file chrony.service does not exist"
        # failure. `map(attribute=...)` on the same data happens to
        # produce the right-looking text via an unrelated later re-
        # templating pass over the *whole rendered expression string* -
        # not available to a mid-filter-chain JSON::Any comparison like
        # this one, which needs the same rendering done explicitly here.
        if (vars = @vars) && (raw_string = attr_value.try(&.raw.as?(String))) &&
           (raw_string.includes?("{{") || raw_string.includes?("{%") || raw_string.includes?("{#"))
          attr_value = JSON::Any.new(VarSubstitutor.new(vars: vars).substitute(raw_string))
        end

        case test
        when "equalto", "eq", "=="
          attr_value == compare_value
        when "ne", "!="
          attr_value != compare_value
        when "undefined"
          attr_value.nil?
        when "sameas"
          # Real Jinja2's `sameas` is Python `is` - object identity, which
          # for a JSON value means "same type AND same value" (unlike
          # `equalto`'s looser Ansible-style cross-type comparison
          # elsewhere in this file - `30000 == true` is meaningfully
          # different from `30000 is sameas true`, and this test exists
          # specifically to tell them apart: linux-system-roles/
          # kernel_settings' own `selectattr('value', 'sameas', true)`
          # guard against a real boolean sysctl value would otherwise
          # match on truthiness alone, treating every non-zero integer
          # sysctl value as if it were the literal `true`).
          !attr_value.nil? && !compare_value.nil? &&
            attr_value.raw.class == compare_value.raw.class && attr_value == compare_value
        else
          !attr_value.nil?
        end
      end

      # A quoted string stays a string; `None` (Jinja/Python's null
      # literal, e.g. the "mountinfo" vars: default in the same task)
      # becomes JSON null; a purely-numeric argument is parsed as a number
      # so `x | default(0)` doesn't stringify to `"0"` for what should
      # stay numeric downstream (e.g. a following `+`-style comparison);
      # anything else is a variable reference (possibly dotted/indexed),
      # resolved against @vars the same way {{ }} substitution would -
      # falling back to the literal text only when no @vars context was
      # given at all (a caller that never needs this, e.g. a filter chain
      # evaluated with no variable scope) or the reference doesn't resolve.
      private def resolve_default_expression(expr : String) : JSON::Any
        expr = expr.strip

        # Jinja2's inline conditional expression (`'1' if COND else '0'`) -
        # dev-sec os_hardening's own dump:/passno: computation
        # (`default('1' if mount.fstype | default(mountinfo.fstype, true)
        # in ['ext3', 'ext4'] else '0', true)`) is written exactly this
        # way. Checked before the quoted-literal check below, which would
        # otherwise misparse the whole ternary as one big quoted string
        # (it starts with `'1'` and the false-branch ends with `'0'`, so
        # naive starts/ends-with-quote matching sees one string spanning
        # both).
        if ternary = split_ternary(expr)
          true_expr, condition, false_expr = ternary
          condition_true = ConditionalEvaluator.evaluate(condition, @vars || Hash(String, JSON::Any).new)
          return resolve_default_expression(condition_true ? true_expr : false_expr)
        end

        return JSON::Any.new(unescape_string_literal(expr[1..-2])) if quoted_literal?(expr)
        return JSON::Any.new(nil) if expr == "None"

        # A literal array/dict (`start=[]`, sum()'s own list-accumulator
        # kwarg default openstack.ansible-hardening's own package-list-
        # building filter chain relies on) - checked before the numeric/
        # var-lookup fallbacks below, which have no notion of `[`/`{` at
        # all and would otherwise resolve "[]" as an (undefined) variable
        # named "[]", stringified back to the literal text "[]" rather
        # than a real empty array.
        if expr.starts_with?('[') && expr.ends_with?(']')
          parsed = (JSON.parse(expr) rescue nil)
          return parsed if parsed && parsed.raw.is_a?(Array)
        elsif expr.starts_with?('{') && expr.ends_with?('}')
          parsed = (JSON.parse(expr) rescue nil)
          return parsed if parsed && parsed.raw.is_a?(Hash)
        end

        # A bare (unquoted) `true`/`false` - Jinja2/Python boolean
        # literals, most commonly `selectattr('value', 'sameas', true)`
        # (linux-system-roles/kernel_settings' own boolean-sysctl-value
        # guard). Checked before the int/float/var-lookup fallbacks below,
        # which would otherwise treat "true"/"false" as a variable name
        # (almost always undefined) and stringify it to the *text*
        # "true"/"false" rather than a real JSON boolean - `sameas`
        # specifically needs the real type to ever compare unequal to a
        # non-boolean attr_value.
        return JSON::Any.new(true) if expr == "true" || expr == "True"
        return JSON::Any.new(false) if expr == "false" || expr == "False"

        if int_val = expr.to_i64?
          return JSON::Any.new(int_val)
        elsif float_val = expr.to_f64?
          return JSON::Any.new(float_val)
        end

        if (vars = @vars) && !expr.empty?
          resolved = VariableLookup.new(vars).resolve(expr)
          resolved ? rerender_if_templated(resolved) : JSON::Any.new(expr)
        else
          JSON::Any.new(expr)
        end
      end

      # Shallow dict merge for the `combine` filter: keys from *other* win
      # over *base* on collision, keys present in only one side pass
      # through unchanged. Non-Hash operands (a `combine` argument that
      # didn't resolve to a dict) are ignored rather than raising, since a
      # stray `default({})` fallback already guarantees an empty Hash in
      # the common case.
      private def combine_hash(base : JSON::Any, other : JSON::Any) : JSON::Any
        base_h = base.raw.is_a?(Hash) ? base.as_h : nil
        other_h = other.raw.is_a?(Hash) ? other.as_h : nil
        return base unless base_h
        return base unless other_h
        merged = base_h.dup
        other_h.each { |key, val| merged[key] = val }
        JSON::Any.new(merged)
      end

      # General single-expression resolver: unlike #resolve_default_expression
      # (which only ever sees a bare variable reference, quoted literal, or
      # ternary - `default`'s own argument grammar), this also understands
      # a `|`-chained filter pipeline and a `{...}` dict literal, both of
      # which show up as `combine`'s own arguments (`combine(sysctl_overwrite
      # | default({}))`).
      #
      # The ternary check MUST run before chain-splitting on the whole
      # expression: dev-sec os_hardening's own `dump:`/`passno:` computation
      # nests a filter chain inside the ternary's own condition (`'1' if
      # mount.fstype | default(mountinfo.fstype, true) in [...] else '0'`),
      # so that top-level `|` belongs to the condition, not to a pipeline
      # applied to the whole ternary. #split_chain has no notion of ternary
      # syntax and would otherwise cut the expression in half right at that
      # pipe, turning "'1' if mount.fstype" into a nonsense base expression
      # and silently discarding the "in [...] else '0'" tail - which is
      # exactly what happened when this used to split_chain first and only
      # checked for ternary inside #resolve_base_expression (too late to
      # matter, since the mis-split had already happened).
      private def resolve_expression(expr : String) : JSON::Any
        expr = expr.strip
        expr = unwrap_outer_parens(expr)

        if ternary = split_ternary(expr)
          true_expr, condition, false_expr = ternary
          condition_true = ConditionalEvaluator.evaluate(condition, @vars || Hash(String, JSON::Any).new)
          return resolve_expression(condition_true ? true_expr : false_expr)
        end

        # Same `+`/`-`/`~`-concatenation delegation resolve_default_arg
        # already has for default()'s own argument - resolve_expression
        # is the more general filter-ARGUMENT resolver (regex_replace's
        # pattern/replacement, selectattr's compare_value, etc.) and
        # never got the same fix, so a `~`-built argument fell straight
        # through to resolve_base_expression, which has no `~` concept
        # at all and returned the literal unparsed text as a bare
        # (always-undefined) variable-name lookup. Found via prometheus.
        # prometheus._common's own `regex_replace(ansible_collection_name
        # ~ '.', '')` (stripping a role's own collection-namespace
        # prefix off its FQCN) - the pattern arg stayed the literal text
        # "ansible_collection_name ~ '.'" instead of the real computed
        # "prometheus.prometheus.", so nothing ever matched and the full
        # FQCN was used verbatim as a systemd service name/template
        # filename, which don't exist under that name.
        if top_level_plus_or_minus?(expr)
          rendered = ExpressionEvaluator.new(@vars || Hash(String, JSON::Any).new).evaluate(expr)
          return (JSON.parse(rendered) rescue JSON::Any.new(rendered))
        end

        parts = self.class.split_chain(expr)
        return JSON::Any.new(nil) if parts.empty?
        parts[1..].reduce(resolve_base_expression(parts[0])) { |acc, filter_expr| apply(acc, filter_expr) }
      end

      private def resolve_base_expression(expr : String) : JSON::Any
        expr = expr.strip

        return JSON::Any.new(unescape_string_literal(expr[1..-2])) if quoted_literal?(expr)
        return JSON::Any.new(nil) if expr == "None"
        # Bare boolean literal (`true`/`false`, not a quoted string) -
        # same class of bug as ExpressionEvaluator's own identical fix:
        # real bug found benchmarking ansible-community.ansible-vault's
        # own `vault_tls_gossip: "{{ lookup('env', 'VAULT_TLS_GOSSIP') |
        # default(false, true) }}"` - the bare `false` fallback argument
        # fell through to a plain (always-undefined) variable lookup on
        # the literal identifier "false", resolving the whole default()
        # call to JSON null (stringifies to "") instead of the literal
        # false it was supposed to substitute.
        return JSON::Any.new(true) if expr == "true" || expr == "True"
        return JSON::Any.new(false) if expr == "false" || expr == "False"
        return parse_dict_literal(expr) if expr.starts_with?('{') && expr.ends_with?('}')

        if int_val = expr.to_i64?
          return JSON::Any.new(int_val)
        elsif float_val = expr.to_f64?
          return JSON::Any.new(float_val)
        end

        if (vars = @vars) && !expr.empty?
          resolved = VariableLookup.new(vars).resolve(expr)
          resolved ? rerender_if_templated(resolved) : JSON::Any.new(nil)
        else
          JSON::Any.new(nil)
        end
      end

      # Parses a `{...}` dict literal (as seen in `default({})`/`combine({a:
      # 1})` arguments, not a real value already carried as JSON::Any) -
      # unquoted keys and single-quoted string values are both real Jinja2
      # dict-literal syntax that plain `JSON.parse` would reject.
      private def parse_dict_literal(expr : String) : JSON::Any
        inner = expr[1..-2].strip
        return JSON::Any.new({} of String => JSON::Any) if inner.empty?

        h = {} of String => JSON::Any
        split_top_level_args(inner).each do |pair|
          key_part, sep, val_part = pair.partition(':')
          next if sep.empty?
          key = key_part.strip.strip("'\"")
          h[key] = resolve_expression(val_part.strip)
        end
        JSON::Any.new(h)
      end

      private def quoted_literal?(expr : String) : Bool
        (expr.starts_with?("'") && expr.ends_with?("'")) ||
          (expr.starts_with?('"') && expr.ends_with?('"'))
      end

      # Strips a single layer of fully-wrapping parens, same rule as
      # ConditionalEvaluator's own copy of this (kept as a separate copy
      # here rather than shared, since the two live in different
      # modules): only unwraps when the parens enclose the *entire*
      # expression, not just its head. Needed so a `default(( 'a' if X
      # else 'b' ))` argument's own #split_ternary (below) actually sees
      # the ` if `/` else ` at depth 0 - real bug found benchmarking
      # ansible-community.ansible-vault's own `vault_tls_certs_path:
      # "{{ lookup('env', 'VAULT_TLS_DIR') | default(('/opt/vault/tls' if
      # (vault_install_hashi_repo) else '/etc/vault/tls'), true) }}"`:
      # the outer parens around the ternary put its own " if "/" else "
      # one level deep, so #split_ternary never matched and the whole
      # parenthesized text fell through to a plain (always-undefined)
      # variable lookup, silently resolving to "".
      private def unwrap_outer_parens(expr : String) : String
        return expr unless expr.starts_with?('(')

        depth = 0
        in_quotes = false
        quote_char = ' '
        expr.each_char_with_index do |char, idx|
          if (char == '"' || char == '\'') && (idx == 0 || expr[idx - 1] != '\\')
            if in_quotes && char == quote_char
              in_quotes = false
            elsif !in_quotes
              in_quotes = true
              quote_char = char
            end
          end

          next if in_quotes

          if char == '('
            depth += 1
          elsif char == ')'
            depth -= 1
            return expr if depth == 0 && idx < expr.size - 1
          end
        end

        expr[1..-2].strip
      end

      # Finds a top-level (outside quotes/brackets) " if " ... " else "
      # pair and splits *expr* into {true_branch, condition, false_branch}
      # - nil if this isn't a ternary at all.
      private def split_ternary(expr : String) : {String, String, String}?
        depth = 0
        quote : Char? = nil
        if_pos = nil
        else_pos = nil

        i = 0
        while i < expr.size
          char = expr[i]
          if q = quote
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
          elsif char == '(' || char == '[' || char == '{'
            depth += 1
          elsif char == ')' || char == ']' || char == '}'
            depth -= 1
          elsif depth == 0
            if if_pos.nil? && expr[i..].starts_with?(" if ")
              if_pos = i
            elsif if_pos && else_pos.nil? && expr[i..].starts_with?(" else ")
              else_pos = i
            end
          end
          i += 1
        end

        return nil unless (start = if_pos) && (finish = else_pos)

        {expr[0...start].strip, expr[(start + 4)...finish].strip, expr[(finish + 6)..].strip}
      end

      # Splits a filter/test's parenthesized argument list on its
      # top-level commas (outside quotes and outside any nested
      # parens/brackets) WITHOUT stripping quotes from each segment - the
      # quoting itself is significant to callers like
      # resolve_default_expression (`'literal'` vs `variable_reference`),
      # unlike parse_filter_args' consumers, which want the quotes already
      # gone. Needed wherever a filter's own argument can itself contain a
      # nested filter call with its own comma
      # (`default('1' if x | default(y, true) in [...] else '0', true)` -
      # dev-sec os_hardening's dump:/passno: computation - the inner
      # `default(y, true)`'s comma must not split the outer call's args).
      # Whether *expr* has a top-level `+` or `-` outside any quote/bracket
      # nesting - used only to decide whether resolve_default_arg needs to
      # hand off to the full ExpressionEvaluator instead of this class's
      # own (ternary-or-filter-chain-only) resolve_expression.
      # Also checks for a top-level `~` - Jinja2's own string-concat
      # operator, distinct from `+` - not just "+"/"-". Found via
      # weareinteractive.users' own `user.home | default(users_home ~
      # '/' ~ user.username)` (building a user's home path from two
      # variables): a `~`-only default argument previously fell through
      # to #resolve_expression below, which has no `~` concept either,
      # so the whole default() argument resolved to nil, collapsing the
      # home path to an empty string ("File does not exist: . Use
      # state=touch to create it.").
      private def top_level_plus_or_minus?(expr : String) : Bool
        depth = 0
        quote : Char? = nil
        expr.each_char do |char|
          if q = quote
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
          elsif "[({".includes?(char)
            depth += 1
          elsif "])}".includes?(char)
            depth -= 1
          elsif depth == 0 && (char == '+' || char == '-' || char == '~')
            return true
          end
        end
        false
      end

      private def split_top_level_args(args : String) : Array(String)
        parts = [] of String
        current = String::Builder.new
        depth = 0
        quote : Char? = nil

        args.each_char do |char|
          if q = quote
            current << char
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
            current << char
          elsif char == '(' || char == '[' || char == '{'
            depth += 1
            current << char
          elsif char == ')' || char == ']' || char == '}'
            depth -= 1
            current << char
          elsif char == ',' && depth == 0
            parts << current.to_s.strip
            current = String::Builder.new
          else
            current << char
          end
        end

        last = current.to_s
        parts << last.strip unless last.empty?
        parts
      end

      private def transform_string(value : JSON::Any, & : String -> String) : JSON::Any
        JSON::Any.new(yield as_string(value))
      end

      private def length_of(value : JSON::Any) : Int32
        case value.raw
        when Array
          value.as_a.size
        when Hash
          value.as_h.size
        when String
          value.as_s.size
        when Nil
          0
        else
          as_string(value).size
        end
      end

      private def as_array(value : JSON::Any) : Array(JSON::Any)
        value.as_a? || [] of JSON::Any
      end

      # Same shape as as_array above - if value is already a JSON Hash,
      # return it; otherwise return an empty Hash (the only sensible
      # "absent" value for a filter that needs a dict to read from,
      # matching how as_array returns an empty Array for a non-Array
      # input). Used by dict2items to be tolerant of undefined / nil /
      # non-dict inputs the way Ansible itself is.
      private def as_hash(value : JSON::Any) : Hash(String, JSON::Any)
        value.as_h? || {} of String => JSON::Any
      end

      # dict2items' transformation core. Walks a Hash in its native
      # insertion order (Crystal Hash is insertion-ordered since 0.34,
      # matching CPython 3.7+ dict semantics) and emits a list of
      # `{key_name => k, value_name => v}` Hashes. The key and value
      # names default to "key"/"value" at the apply() call site.
      private def dict_to_items(hash : Hash(String, JSON::Any), key_name : String, value_name : String) : Array(JSON::Any)
        hash.map do |k, v|
          JSON::Any.new({
            key_name   => JSON::Any.new(k),
            value_name => v,
          })
        end
      end

      # items2dict' transformation core. Inverse of dict_to_items:
      # takes a list of `{key_name, value_name, ...}` dicts and produces
      # a single dict mapping key_name -> value_name. Elements that
      # aren't dicts, or that don't carry the named key field, are
      # silently dropped (matches real Ansible's tolerance: malformed
      # list elements don't fail the whole filter, they just contribute
      # nothing to the output). On a key collision later in the list
      # wins (same precedence as a `combine` chain).
      private def items_to_dict(items : Array(JSON::Any), key_name : String, value_name : String) : Hash(String, JSON::Any)
        result = {} of String => JSON::Any
        items.each do |item|
          next unless item.as_h?
          h = item.as_h
          k = h[key_name]?.try(&.as_s?)
          next unless k
          v = h[value_name]?
          result[k] = v if v
        end
        result
      end

      # Same shape as JinjaFilters.flatten_array (jinja_filters.cr,
      # Crinja's own registry) - see the "flatten" filter case above
      # for why this hand-rolled evaluator needs its own copy.
      private def flatten_array(items : Array(JSON::Any), max_depth : Int32?, skip_nulls : Bool, depth : Int32 = 0) : Array(JSON::Any)
        result = [] of JSON::Any
        items.each do |item|
          raw = item.raw
          if raw.is_a?(Array(JSON::Any)) && (max_depth.nil? || depth < max_depth)
            result.concat(flatten_array(raw, max_depth, skip_nulls, depth + 1))
          elsif skip_nulls && raw.nil?
            # dropped
          else
            result << item
          end
        end
        result
      end

      # Stringifies a JSON::Any the way Ansible/Jinja2 would when a filter
      # needs to treat it as text (e.g. join's own elements, replace's own
      # input) - booleans render capitalized (`True`/`False`), matching
      # VariableLookup#format_value's own convention for template
      # interpolation, since a filter's own string output ultimately feeds
      # back into the same template text either way.
      private def as_string(value : JSON::Any) : String
        case value.raw
        when String
          value.as_s
        when Int64, Int32
          value.as_i64.to_s
        when Float64
          value.as_f.to_s
        when Bool
          value.as_bool ? "True" : "False"
        when Nil
          ""
        when Array, Hash
          value.to_json
        else
          value.to_s
        end
      end

      private def python_json_dump(value : JSON::Any) : String
        String.build { |io| python_json_dump(value, io) }
      end

      private def python_json_dump(value : JSON::Any, io : IO)
        case raw = value.raw
        when Nil
          io << "null"
        when Bool
          io << raw
        when String
          raw.to_json(io)
        when Int64, Int32, Float64
          io << raw
        when Array
          io << '['
          raw.each_with_index do |item, index|
            io << ", " if index > 0
            python_json_dump(item, io)
          end
          io << ']'
        when Hash
          io << '{'
          first = true
          raw.each do |key, item|
            io << ", " unless first
            first = false
            key.to_s.to_json(io)
            io << ": "
            python_json_dump(item, io)
          end
          io << '}'
        else
          raw.to_s.to_json(io)
        end
      end

      private def numeric(value : JSON::Any) : Float64
        case value.raw
        when Int64, Int32
          value.as_i64.to_f64
        when Float64
          value.as_f
        else
          as_string(value).to_f64? || 0.0
        end
      end

      # Unescapes the common backslash escape sequences a real Python/
      # Jinja2 single- or double-quoted string LITERAL supports (`\\` ->
      # `\`, `\'`/`\"` -> the literal quote, `\n`/`\t` -> real newline/
      # tab) - quoted_literal? extraction elsewhere in this file just
      # strips the surrounding quote characters, with no unescaping at
      # all. Found via prometheus.prometheus._common's own preflight.yml:
      # `reject('match', '.+:\\d+$')`, written inside a YAML `>-` folded
      # scalar (not a double-quoted YAML string, so YAML itself does no
      # backslash processing) - the regex pattern arrived as the two RAW
      # characters `\\d` (backslash, backslash, d) instead of the single
      # escaped backslash + digit-class `\d` real Python/Jinja string-
      # literal unescaping produces, so the regex matched a literal
      # "\d" substring instead of a digit run, and never matched real
      # host:port text like "0.0.0.0:9100" - `reject(...)` silently
      # rejected nothing.
      private def unescape_string_literal(text : String) : String
        String.build do |io|
          i = 0
          while i < text.size
            if text[i] == '\\' && i + 1 < text.size
              case text[i + 1]
              when '\\' then io << '\\'
              when '\'' then io << '\''
              when '"'  then io << '"'
              when 'n'  then io << '\n'
              when 't'  then io << '\t'
              else
                io << text[i] << text[i + 1]
              end
              i += 2
            else
              io << text[i]
              i += 1
            end
          end
        end
      end

      private def truthy?(value : JSON::Any) : Bool
        case value.raw
        when Nil
          false
        when Bool
          value.as_bool
        when String
          !value.as_s.empty? && value.as_s != "0" && value.as_s.downcase != "false"
        when Int64, Int32
          value.as_i64 != 0
        when Float64
          value.as_f != 0.0
        when Array
          !value.as_a.empty?
        when Hash
          !value.as_h.empty?
        else
          true
        end
      end

      # Decorate-sort-undecorate. This replaced a `sort { compare_json(l,
      # r) }` whose comparator stringified *and* attempted a Float64 parse
      # of both operands on every comparison, so an n-element list did
      # O(n log n) of both over the same values; computing each element's
      # key once makes that O(n).
      #
      # The numeric-vs-lexicographic decision is now made once for the
      # whole list rather than per pair. For a homogeneous list - every
      # element numeric, or none - that is exactly the old ordering. It
      # differs only for a *mixed* list, where the old per-pair rule
      # compared some pairs numerically and others lexicographically:
      # an intransitive comparator whose result was already arbitrary.
      private def sort_json(items : Array(JSON::Any)) : Array(JSON::Any)
        keys = items.map { |item| as_string(item) }

        if keys.all?(&.to_f64?)
          items.map_with_index { |item, index| {keys[index].to_f64, item} }
            .sort! { |left, right| left[0] <=> right[0] }
            .map { |pair| pair[1] }
        else
          items.map_with_index { |item, index| {keys[index], item} }
            .sort! { |left, right| left[0] <=> right[0] }
            .map { |pair| pair[1] }
        end
      end

      # Parses `name='value'`/`name="value"` out of a filter's argument
      # list - only what `map(attribute=...)` needs, not general keyword
      # argument parsing.
      # Recursively sorts a JSON object's keys - the JSON counterpart of
      # #sort_yaml_keys-style helpers already used for to_nice_yaml's own
      # Crinja copy, needed here for to_nice_json's sort_keys= default.
      private def sort_json_keys(value : JSON::Any) : JSON::Any
        case raw = value.raw
        when Hash
          sorted = raw.to_a.sort_by { |(k, _)| k }
          JSON::Any.new(sorted.to_h { |(k, v)| {k, sort_json_keys(v)} })
        when Array
          JSON::Any.new(raw.map { |v| sort_json_keys(v) })
        else
          value
        end
      end

      HUMAN_READABLE_SUFFIXES = {"Bytes", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"}
      HUMAN_READABLE_BIT_SUFFIXES = {"bits", "Kb", "Mb", "Gb", "Tb", "Pb", "Eb", "Zb", "Yb"}

      # Mirrors real Ansible's own bytes_to_human/human_to_bytes
      # (module_utils.common.text.formatters) closely enough for the
      # common cases - both base-1024, `isbits:` selects the bit-count
      # suffix table (and multiplies the byte count by 8 first) rather
      # than switching to a base-1000 divisor, matching real Ansible's
      # own implementation exactly (a common misconception is that
      # "bits" implies decimal/SI units - it doesn't, here).
      private def format_human_readable(bytes : Int64, isbits : Bool) : String
        value = isbits ? bytes.to_f * 8 : bytes.to_f
        suffixes = isbits ? HUMAN_READABLE_BIT_SUFFIXES : HUMAN_READABLE_SUFFIXES
        suffixes.each_with_index do |suffix, i|
          unit = 1024.0 ** i
          next_unit = 1024.0 ** (i + 1)
          if value < next_unit || i == suffixes.size - 1
            return i == 0 ? "#{value.to_i} #{suffix}" : "%.2f %s" % [value / unit, suffix]
          end
        end
        "#{bytes} Bytes"
      end

      private def parse_human_to_bytes(str : String) : Int64
        match = str.strip.match(/^([\d.]+)\s*([A-Za-z]*)$/)
        return str.to_i64? || 0_i64 unless match

        number = match[1].to_f
        unit = match[2].downcase
        multiplier = case unit
                     when "", "b", "bytes" then 1_i64
                     when "kb"              then 1024_i64
                     when "mb"              then 1024_i64 ** 2
                     when "gb"              then 1024_i64 ** 3
                     when "tb"              then 1024_i64 ** 4
                     when "pb"              then 1024_i64 ** 5
                     else                        1_i64
                     end
        (number * multiplier).to_i64
      end

      # Mirrors Python's os.path.normpath: collapses `.`/`..`/redundant
      # `/` segments without ever making a relative path absolute.
      private def normalize_path(path : String) : String
        return "." if path.empty?
        absolute = path.starts_with?('/')
        parts = path.split('/').reject { |p| p.empty? || p == "." }

        result = [] of String
        parts.each do |part|
          if part == ".." && !result.empty? && result.last != ".."
            result.pop
          elsif part == ".." && !absolute
            result << part
          elsif part != ".."
            result << part
          end
        end

        joined = result.join("/")
        absolute ? "/#{joined}" : (joined.empty? ? "." : joined)
      end

      # Mirrors Python's os.path.commonpath: the longest shared leading
      # sequence of path SEGMENTS (not a naive character prefix) across
      # every path in *paths*.
      private def common_path(paths : Array(String)) : String
        return "" if paths.empty?
        segments = paths.map { |p| p.split('/').reject(&.empty?) }
        first = segments.first
        common = first.each_with_index.take_while { |seg, i| segments.all? { |s| s[i]? == seg } }.map(&.[0])
        prefix = paths.first.starts_with?('/') ? "/" : ""
        "#{prefix}#{common.join("/")}"
      end

      # itertools.combinations(array, n) - every n-length combination,
      # order-independent, no element reused within one combination.
      private def combinations(array : Array(JSON::Any), n : Int32) : Array(Array(JSON::Any))
        return [[] of JSON::Any] if n == 0
        return [] of Array(JSON::Any) if n > array.size || array.empty?

        head = array.first
        tail = array[1..]
        with_head = combinations(tail, n - 1).map { |c| [head] + c }
        without_head = combinations(tail, n)
        with_head + without_head
      end

      # itertools.permutations(array, n) - every n-length ORDERED
      # arrangement, no element reused within one arrangement.
      private def permutations(array : Array(JSON::Any), n : Int32) : Array(Array(JSON::Any))
        return [[] of JSON::Any] if n == 0
        return [] of Array(JSON::Any) if n > array.size || array.empty?

        result = [] of Array(JSON::Any)
        array.each_with_index do |item, i|
          rest = array[0...i] + array[(i + 1)..]
          permutations(rest, n - 1).each { |p| result << ([item] + p) }
        end
        result
      end

      private def parse_kwarg(args : String, name : String) : String?
        if match = args.match(/#{name}\s*=\s*(['"])(.*?)\1/)
          match[2]
        end
      end

      # Same as parse_kwarg, but for a kwarg whose value isn't necessarily
      # a quoted string - `start=[]` (sum()'s own list-accumulator kwarg)
      # needs the full literal/expression resolver, not just quote
      # stripping.
      private def parse_kwarg_expr(args : String, name : String) : JSON::Any?
        split_top_level_args(args).each do |part|
          part = part.strip
          next unless part.starts_with?("#{name}=")
          return resolve_default_expression(part[(name.size + 1)..])
        end
        nil
      end

      # Parse a single filter argument (remove quotes)
      private def parse_filter_arg(arg : String) : String
        arg = arg.strip
        if arg.starts_with?("'") && arg.ends_with?("'")
          arg[1..-2]
        elsif arg.starts_with?('"') && arg.ends_with?('"')
          arg[1..-2]
        else
          arg
        end
      end

      # Parse multiple filter arguments
      private def parse_filter_args(args : String) : Array(String)
        # Simple parser - split by comma, handle quotes
        result = [] of String
        # String::Builder rather than `current += char`, which allocates a
        # whole new String per character (O(n^2) in the argument length) -
        # the same accumulator fix already applied to
        # ConditionalEvaluator.split_by_operator, and the same shape
        # #split_chain above already uses.
        current = String::Builder.new
        in_quotes = false
        quote_char = ' '

        args.each_char do |char|
          case char
          when '\'', '"'
            if in_quotes && char == quote_char
              in_quotes = false
            elsif !in_quotes
              in_quotes = true
              quote_char = char
            else
              current << char
            end
          when ','
            if in_quotes
              current << char
            else
              result << current.to_s.strip
              current = String::Builder.new
            end
          else
            current << char
          end
        end

        # Emptiness is tested on the *unstripped* accumulator, as before:
        # a trailing whitespace-only segment still contributes an empty
        # argument rather than being dropped.
        last = current.to_s
        result << last.strip unless last.empty?
        result.map { |arg| parse_filter_arg(arg) }
      end
    end
  end
end
