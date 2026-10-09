require "json"

module Krikri
  module VariableSubstitutor
    # The `case filter_name` dispatch behind FilterEngine#apply - every supported
    # filter's implementation branch (REGEX_FILTER_CALL, the name/args parser,
    # serves only this dispatch's unknown-filter error message)
    class FilterEngine
      # The name part includes dots so a collection-qualified unknown
      # filter WITH arguments (`nephelaiio.plugins.sorted_get(overrides)`)
      # reports its full dotted name in the unknown-filter error, exactly
      # as Ansible names it - `\w+` alone stopped at the first dot,
      # so the whole `name(args)` text became the "filter name" in the
      # message. No implemented filter name contains a dot (the FQCN
      # spellings are stripped down to bare names before this regex
      # runs), so this only ever changes the ERROR message, never the
      # dispatch.
      REGEX_FILTER_CALL = /^([\w.]+)\s*\((.*)\)$/m

      # Apply a single filter to a value.
      # Example: myvar | default('value')
      def apply(value : JSON::Any, filter_expr : String, chain_root : String? = nil) : JSON::Any
        @chain_root = chain_root if chain_root
        # `ansible.builtin.`-prefixed filter names (a real, if uncommon,
        # spelling - Ansible's own core filters are all reachable
        # via this FQCN too, not just the bare name) never matched any
        # `case filter_name` branch below at all, silently falling to
        # the unknown-filter passthrough - found live via
        # prometheus.prometheus.prometheus's own `map('ansible.builtin.
        # fileglob') | flatten | map('ansible.builtin.realpath')` chain
        # (round 30). Stripped once here so every filter branch below
        # matches either spelling.
        filter_expr = filter_expr.lchop("ansible.builtin.") if filter_expr.starts_with?("ansible.builtin.")
        # same carve-out for the ansible.utils ipaddr family's FQCN
        # spelling (`| ansible.utils.ipaddr`) - but only for a name the
        # family actually implements, so a genuinely-unknown
        # `ansible.utils.foo` still errors with the full FQCN in the
        # message, as Ansible names it.
        if filter_expr.starts_with?("ansible.utils.")
          rest = filter_expr.lchop("ansible.utils.")
          bare = rest.match(/^(\w+)/).try(&.[1])
          filter_expr = rest if bare && IpAddrCore::FAMILY_FILTERS.includes?(bare)
        end
        # Same treatment for community.general's collection-qualified
        # spellings (`| community.general.lists_mergeby`) - a community.
        # general filter is commonly reachable both ways, so gate the
        # strip on a bare name this dispatch actually implements (the
        # same carve-out the ansible.utils family gets) and let a
        # genuinely-unknown `community.general.foo` still error with the
        # full FQCN in the message, as Ansible names it.
        if filter_expr.starts_with?("community.general.")
          rest = filter_expr.lchop("community.general.")
          bare = rest.match(/^(\w+)/).try(&.[1])
          filter_expr = rest if bare && KNOWN_FILTER_NAMES.includes?(bare)
        end

        if match = filter_expr.match(REGEX_FILTER_CALL)
          filter_name = match[1]
          filter_args = match[2]
        else
          filter_name = filter_expr
          filter_args = ""
        end

        case filter_name
        when "fileglob"
          # Ansible's ansible.builtin.fileglob LOOKUP plugin, usable
          # as a filter via `map('ansible.builtin.fileglob')` (distinct
          # from the separate `with_fileglob:` loop keyword, which
          # TaskExecutor#resolve_fileglob already handles). Ansible
          # returns the empty list for a pattern matching no files (not
          # an error) - without this, an unrecognized filter name fell
          # to the passthrough below, leaving the RAW glob pattern
          # string as if it were already a real, matched file path.
          JSON::Any.new(Dir.glob(as_string(value)).sort!.map { |pth| JSON::Any.new(pth) })
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
          # value, not a mistake) is falsy, so Ansible replaces it
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
          # Ansible/Jinja2 filter (Python's os.path.dirname) -
          # entirely unimplemented, so it fell through to the unknown-
          # filter passthrough (returning the full path unchanged), found
          # via geerlingguy.mysql's own "Ensure error log directory
          # exists": `path: "{{ mysql_log_error | dirname }}"` with
          # `state: directory`. Left unchanged, that created a directory
          # at the *full* log-error path itself ("/var/log/mysql/
          # mysql.err") rather than its parent ("/var/log/mysql"), so
          # mysqld's own attempt to open its error log at that same path
          # found a directory instead of a file and failed to start.
          JSON::Any.new(FilterCore.dirname(as_string(value)))
        when "basename"
          JSON::Any.new(FilterCore.basename(as_string(value)))
        when "length", "count"
          # Python's len() on a None/float/int/bool input raises
          # TypeError, which Ansible wraps as "The filter plugin
          # 'ansible.builtin.length' failed: object of type 'NoneType'
          # has no len()" (lotusnoir.apps_consul_exporter round 5210000:
          # first_found errors='ignore' no-match -> None -> `params |
          # length > 0` in a when:, real fails the task, krikri's raw
          # raise got the generic "Error while evaluating conditional:"
          # prefix instead of the filter-plugin wrapper).
          begin
            JSON::Any.new(length_of(value).to_i64)
          rescue ex : FilterPluginError
            raise ex
          rescue ex
            raise Krikri::FilterPluginError.new(
              "The filter plugin 'ansible.builtin.length' failed: #{ex.message}", ex.message || "filter failed")
          end
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
          # flatten(levels=none, skip_nulls=true) - Ansible's own
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
          # Positional or keyword (`flatten(1)` / `flatten(levels=1)`);
          # #parse_kwarg only reads quoted values, so an unquoted
          # `levels=1` used to be silently ignored.
          positional, kwargs = split_positional_and_kwargs(filter_args, ["levels", "skip_nulls"])
          levels = (kwargs["levels"]? || positional[0]?).try(&.as_i64?).try(&.to_i32)
          skip_nulls_arg = kwargs["skip_nulls"]? || positional[1]?
          skip_nulls = skip_nulls_arg ? truthy?(skip_nulls_arg) : true
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
          # Jinja2's `first`/`last` work on any sequence, including
          # a plain string (Python treats a str as a sequence of
          # characters) - `as_array` only ever extracts a real JSON
          # array, silently returning nil/"" for a String value instead
          # of its first character. This case still matters for a
          # genuine plain string (`"hello" | first` -> "h") - regex_
          # search itself now returns a real one-element LIST for a
          # group_ref call (see that filter's own case above), so a
          # `regex_search(...) | first` chain reaches the Array branch
          # below instead of this one.
          #
          # A genuinely empty sequence (an empty ARRAY specifically, not
          # merely "not an array at all" - `as_array` also returns `[]`
          # for an undefined/non-array value, a separate, still-deferred
          # class of gap this deliberately does NOT touch) raises here,
          # matching Jinja2's own `do_first`: `next(iter(seq))`
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
          jinja_extreme(as_array(value), prefer_less: true) || JSON::Any.new(nil)
        when "max"
          jinja_extreme(as_array(value), prefer_less: false) || JSON::Any.new(nil)
        when "int"
          # Jinja2's own `int` filter (do_int) truncates a native
          # float/int directly (Python's `int(42.5) == 42`) - going
          # through #as_string first (as this used to do unconditionally)
          # turns a Float64 into its own decimal-point STRING repr
          # ("256.0"), and Crystal's strict `String#to_i64?` rejects any
          # decimal point outright, always falling to the `|| 0_i64`
          # default. `{{ 256.0 | int }}` (or ANY float, not just one
          # arriving via a division result) rendered "0" instead of
          # "256". Found via geerlingguy.swap's own check-size.yml
          # (`(stat.size / 1024 / 1024) | int`) once division itself was
          # fixed - a division result is always a float in Jinja2,
          # so nearly every `int`-filtered division hit this. A numeric
          # string still falls through to the string-parsing path below,
          # itself widened to accept "42.5"-style decimal strings the
          # same way Jinja2 does (int() on the string fails, falls
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
          # Ansible's own `bool` filter (ansible.module_utils.
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
          # keywords) - verified directly against ansible-playbook
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
            # A deferred leaf (see #strict_render_deferred_leaves) extracted
            # by map(attribute=...) is genuinely ACCESSED here -
            # Ansible renders it (and fails on an undefined-bottoming
            # template), and so did this engine before the chain head
            # stopped eagerly raising on the whole structure. Strict
            # re-render keeps that failure; already-rendered values pass
            # through the marker check untouched.
            JSON::Any.new(as_array(value).map do |item|
              extracted = item.raw.is_a?(Hash) ? (item[attr]? || JSON::Any.new(nil)) : JSON::Any.new(nil)
              if (vars = @vars) && (raw_s = extracted.try(&.raw.as?(String))) &&
                 (raw_s.includes?("{{") || raw_s.includes?("{%") || raw_s.includes?("{#")) &&
                 !chain_root_unsafe? && !UnsafeValues.unsafe_text?(raw_s)
                JSON::Any.new(VarSubstitutor.new(vars: vars).strict_render(raw_s))
              else
                extracted
              end
            end)
          elsif inner_name = parse_filter_args(filter_args)[0]?
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
          apply_selectattr(value, filter_args, false)
        when "rejectattr"
          # rejectattr('stat.exists') - the inverse of selectattr, with
          # the same argument shape, but its own no-test-given default
          # differs from selectattr's: Jinja2 3.x's own no-test
          # default for rejectattr is truthiness of the attribute value
          # (see the "truthy" case in selectattr_matches?), not
          # selectattr's "defined" presence check - a `stat.exists:
          # false` entry is perfectly well-defined but must still be
          # picked (rejected) here. Ansible's idiom for "run only if
          # ALL of a registered
          # looped stat:'s results say the file exists":
          # `_concat_stat.results | rejectattr('stat.exists') | list |
          # length == 0` - rejectattr picks out the results whose
          # stat.exists is falsy; an empty picked list means nothing is
          # missing. Found via round 813028's
          # volker-raschek.certificate_authority, whose shared
          # concatenate.yml helper task file gates a task exactly this
          # way - rejectattr was entirely unrecognized before, so the
          # when: hard-failed and the task was always skipped, even when
          # every stat'd file genuinely existed.
          apply_selectattr(value, filter_args, true)
        when "to_datetime"
          # to_datetime('%b %d, %Y') - dev-sec os_hardening's own
          # password-ageing verification parses `chage -l`'s date output
          # this way, then subtracts two of them for a day-count assert.
          # Ansible's default format (no argument) is
          # '%Y-%m-%d %H:%M:%S'. Represented as a tagged JSON object
          # (epoch seconds) rather than a native type FilterEngine has no
          # concept of - ExpressionEvaluator's `-` operator (ARC:
          # combine_minus) knows to recognize and subtract two of these
          # into a timedelta, itself tagged the same way so `.days`
          # dotted access on the result works via the ordinary Hash-key
          # path.
          parse_to_datetime(value, filter_args.strip.empty? ? "%Y-%m-%d %H:%M:%S" : parse_filter_arg(filter_args))
        when "sum"
          # sum(attribute='packages', start=[]) - Jinja2's sum()
          # filter, entirely unimplemented before (fell through to the
          # unknown-filter passthrough, returning the *selected items
          # themselves* unchanged rather than summing/concatenating
          # them). With a list-valued start:, this concatenates each
          # item's attribute value (or the item itself, with no
          # attribute=) onto start - openstack.ansible-hardening's own
          # package install/removal tasks build their final package
          # list this way (`stig_packages_rhel7 | selectattr(...) |
          # selectattr(...) | sum(attribute='packages', start=[])`).
          # With a numeric start: (Jinja2's own default, 0), sums
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
            any_float = start_value.raw.is_a?(Float64)
            items.each do |item|
              any_float ||= item.raw.is_a?(Float64)
              total += numeric(item)
            end
            # Jinja2 keeps sum() of all-int items an int (`[1,2,3] |
            # sum` renders "6", not "6.0") - only a float input makes the
            # result a float.
            any_float ? JSON::Any.new(total) : JSON::Any.new(total.to_i64)
          end
        when "combine"
          # combine(other1, other2, ..., recursive=False, list_merge='replace')
          # - dict merge, later positional arguments win on key collisions.
          # dev-sec os_hardening chains several of these (`sysctl_config |
          # combine(sysctl_custom_config | default({})) | combine(...)`) to
          # layer per-OS overrides on top of role defaults; was previously
          # entirely unimplemented (fell through to the `else` passthrough
          # below), silently discarding every merge-in argument.
          #
          # Phase-1 consolidation (after the dict2items pilot): the
          # hand-rolled merge this dispatch used to run (#combine_hash,
          # mirrored but independent of jinja_filters.cr's Crinja-side
          # registration) is retired for this name - it routes through the
          # ONE native `Crinja.filter(:combine)` registration via
          # #delegate_to_jinja_filter, now with positional varargs (the
          # multi-dict shape dict2items never needed). The kwarg parsing
          # stays here verbatim (see below for why it can't use
          # #parse_kwarg) and feeds pre-built Crinja values, because
          # `recursive` must arrive as a real Bool - the text "false"
          # would be truthy to the Crinja filter's `truthy?`. Behavior
          # contract unchanged and still enforced by
          # test/unit/lazy_dict_templating_test.cr (recursive deep-merge
          # plus every list_merge mode against ansible-core 2.19).
          # #combine_hash is deleted too now: lists_mergeby migrated
          # onto its own Crinja registration (see the lists_mergeby
          # case below), so nothing else called it.
          recursive_arg = false
          list_merge_arg = "replace"
          positional_args = [] of String
          split_top_level_args(filter_args).each do |arg|
            part = arg.strip
            m = part.match(/^recursive\s*=\s*(.+)$/)
            if m
              v = m[1].strip.downcase
              recursive_arg = v == "true" || v == "1"
            else
              m = part.match(/^list_merge\s*=\s*(.+)$/)
              if m
                list_merge_arg = m[1].strip.delete("'\"")
              else
                positional_args << part
              end
            end
          end
          crinja_kwargs = Hash(String, JSON::Any).new
          crinja_kwargs["recursive"] = JSON::Any.new(recursive_arg)
          crinja_kwargs["list_merge"] = JSON::Any.new(list_merge_arg)
          delegate_to_jinja_filter(
            "combine", value, crinja_kwargs,
            positional_args.map { |arg_expr| resolve_expression(arg_expr) },
          )
        when "lists_mergeby", "list_mergeby"
          # lists_mergeby(list2, list3, ..., 'key', recursive=False,
          # list_merge='replace') - community.general's own filter (the
          # pre-3.x `list_mergeby` spelling kept as its deprecated
          # alias): merges two or more lists of dicts into a single
          # list, resolving items that share the same merge-key value
          # by merging their dicts together (later lists win on
          # collisions, exactly like `combine`'s later-positional-wins;
          # `recursive=` and `list_merge=` carry combine's same
          # merge semantics). Items whose key value appears in only
          # one list pass through untouched; result order is
          # first-seen key order (real CPython 3.7+ dict semantics,
          # same ordering the Crinja-side dict2items relies on).
          # Entirely unimplemented before - found via a real-host
          # benchmark round where a role's own vars assembly (lists of
          # per-source dicts keyed by name) hit the unknown-filter
          # error and the task failed before it could reach the
          # (pre-existing, role-side) bug Ansible dies on further
          # downstream.
          #
          # Phase-1 cleanup (after the combine migration): the
          # hand-rolled merge (#lists_mergeby_lists + the shared
          # #combine_hash) is retired - this dispatch routes through
          # the ONE native `Crinja.filter(:lists_mergeby)` registration
          # via #delegate_to_jinja_filter, same as combine/dict2items.
          # The kwarg parsing stays here verbatim (same reason as
          # combine's: `recursive` must arrive as a real Bool, not its
          # truthy text form) and the merge key is resolved and passed
          # as the LAST vararg, the position the registration's
          # signature expects. The error contract (raise on a non-dict
          # item or an item missing the merge key, rather than
          # silently skipping - which would hide the role's own data
          # bug) now lives in the registration, enforced by
          # test/unit/lists_mergeby_test.cr through this delegated
          # path.
          recursive_arg = false
          list_merge_arg = "replace"
          positional_args = [] of String
          split_top_level_args(filter_args).each do |arg|
            part = arg.strip
            m = part.match(/^recursive\s*=\s*(.+)$/)
            if m
              v = m[1].strip.downcase
              recursive_arg = v == "true" || v == "1"
            else
              m = part.match(/^list_merge\s*=\s*(.+)$/)
              if m
                list_merge_arg = m[1].strip.delete("'\"")
              else
                positional_args << part
              end
            end
          end
          # Ansible fails the task on a missing merge key
          # (TypeError/KeyError from the Python side) - not silently an
          # empty list, which would hide the role's own data bug.
          raise "lists_mergeby: missing merge key argument" if positional_args.empty?
          merge_key = as_string(resolve_expression(positional_args.pop))
          crinja_kwargs = Hash(String, JSON::Any).new
          crinja_kwargs["recursive"] = JSON::Any.new(recursive_arg)
          crinja_kwargs["list_merge"] = JSON::Any.new(list_merge_arg)
          delegate_to_jinja_filter(
            "lists_mergeby", value, crinja_kwargs,
            positional_args.map { |arg_expr| resolve_expression(arg_expr) } + [JSON::Any.new(merge_key)],
          )
        when "strftime"
          # strftime(second=None, utc=False) - ansible-core's
          # strftime filter takes the PIPED value as the FORMAT string
          # and the epoch seconds as the first positional argument
          # (ansible-core source: `def strftime(string_format, second=None,
          # utc=False)`). Live-verified against 2.19.11:
          #   `'\%Y-\%m-\%d' | strftime(0, 'UTC')` -> "1970-01-01"
          # and the pre-2.19 idiom `ts | to_datetime | strftime('%H:%M')`
          # (piped datetime, format as the argument) now FAILS upstream
          # with "Invalid value for epoch value" - so the same shape
          # fails the task here too rather than rendering with the old
          # piped-as-epoch convention. No argument means "now" on both
          # engines (nondeterministic by design; benchmark plays that
          # need byte-stable output always pass an epoch).
          # Formatting uses Crystal's Time#to_s directive subset - the
          # same documented subset jinja_filters.cr's registration spells
          # out (Python-only %-d/%-m/%f render literally, they don't
          # raise).
          positional, kwargs = split_positional_and_kwargs(filter_args, ["utc"])
          epoch_arg = positional[0]?
          utc_arg = positional[1]? || kwargs["utc"]?
          # Real order of operations: the epoch argument is validated
          # FIRST (float(second) inside strftime()), so the old
          # `ts | to_datetime | strftime('%H:%M')` idiom - piped datetime,
          # format as the epoch argument - fails with "Invalid value for
          # epoch value (%H:%M)" (live-verified against 2.19.11), NOT an
          # error about the format. A non-string piped value with no
          # epoch argument only fails later inside time.strftime().
          unless epoch_arg.nil? || epoch_arg.raw == nil
            second_str = as_string(epoch_arg)
            seconds = second_str.to_i64? || second_str.to_f64?.try(&.to_i64)
            raise "strftime: Invalid value for epoch value (#{second_str})" if seconds.nil?
          end
          unless value.raw.is_a?(String)
            raise "strftime: string_format must be a string (#{as_string(value).inspect})"
          end
          fmt = value.as_s
          # Python truthiness for the utc flag: anything but nil/false/0
          # /empty-string is truthy (real `if utc:` - so the literal
          # string 'UTC' IS truthy, and so is the string 'false').
          utc_truthy = case raw = utc_arg.try(&.raw)
                       when Nil     then false
                       when Bool    then raw
                       when Int64   then raw != 0
                       when Float64 then raw != 0.0
                       when String  then !raw.empty?
                       else              true
                       end
          if epoch_arg.nil? || epoch_arg.raw == nil
            time = utc_truthy ? Time.utc : Time.local
          else
            epoch_txt = as_string(epoch_arg)
            seconds = epoch_txt.to_i64?
            if seconds.nil?
              if float_val = epoch_txt.to_f64?
                seconds = float_val.to_i64
              end
            end
            raise "strftime: Invalid value for epoch value (#{epoch_txt})" if seconds.nil?
            time = utc_truthy ? Time.unix(seconds) : Time.unix(seconds).to_local
          end
          JSON::Any.new(time.to_s(fmt))
        when "random"
          # Jinja2's do_random: an int operand means "random int less
          # than this" (Python's randrange), a sequence operand means
          # "random element" (choice), and a `seed=` kwarg makes both
          # deterministic. Found missing via lean_delivery.jenkins_slave's
          # own password generation:
          # `65534 | random(seed=inventory_hostname)` - a register:'d
          # password must come out IDENTICAL on every idempotent rerun on
          # the same host, which is exactly what the seed pins down.
          #
          # Phase-3 consolidation slice #5: the hand-rolled copy (and its
          # #random_choice/#py_random_for_seed helpers) is retired for the
          # ONE native Crinja.filter(:random) registration (jinja_filters.cr)
          # via #delegate_to_jinja_filter, same seed= kwarg shape. Seeded
          # runs use PyRandom on both engines, so krikri and
          # ansible-playbook produce the SAME value for the same seed;
          # unseeded runs stay NONdeterministic on both (the registration's
          # unseeded path previously fell into a constant-seeded PyRandom,
          # so every unseeded call returned the same value - fixed toward
          # Jinja's nondeterminism alongside this migration).
          # krikri-jinja's native random filter now matches Ansible's
          # PyRandom semantics for both integer and string seeds, so the
          # deterministic register:'d password value is identical to
          # ansible-playbook's.
          positional, kwargs = split_positional_and_kwargs(filter_args, ["seed"])
          args = positional.map(&.to_json)
          if seed = kwargs["seed"]?
            args << "seed=#{seed.to_json}"
          end
          result = KrikriJinja.evaluate_expression(
            "__value__ | random(#{args.join(", ")})", {"__value__" => value},
            host_context: JinjaHostContext.new(@vars || Hash(String, JSON::Any).new)
          )
          return result || JSON::Any.new(nil)
        when "map_format"
          # The nephelaiio.plugins collection's custom filter (NOT
          # community.general - no such filter exists there), found
          # missing via nephelaiio.packetbeat's own defaults/main.yml:
          # `hosts: "{{ hosts | map('map_format', '%s:' + port) | list }}"`.
          # Shared core in FilterCore.map_format (both evaluators use it);
          # reachable through map() above since that recurses into #apply
          # per item. A missing pattern argument leaves the value
          # unchanged rather than raising (real Python's call-time
          # TypeError surfaces as a generic task failure either way).
          args = split_top_level_args(filter_args)
          pattern = args[0]?.try { |arg| resolve_expression(arg) }
          pattern ? FilterCore.map_format(value, pattern) : value
        when "dict2items"
          # dict2items(key_name='key', value_name='value') - Ansible's
          # own filter (NOT standard Jinja2; the Crinja corpus confirms
          # Python/Jinja2 reject it as "No filter named 'dict2items'"),
          # converts a dict to a list of {key: k, value: v} items so
          # `loop: "{{ my_dict | dict2items }}"` can iterate. dev-sec
          # os_hardening's own `os_hardening_set_os_variables.yml` uses
          # exactly this shape (`with_dict` semantics) to walk a flat
          # `{mount_point: {mode: ..., owner: ...}}` config.
          #
          # Phase-1 consolidation pilot (SUGGESTED_CRINJA_NEXT_STEPS.md):
          # the parallel hand-rolled JSON::Any copy this dispatch used to
          # carry is deleted - the name now routes through the ONE native
          # `Crinja.filter` registration (jinja_filters.cr, live-
          # differentialed against ansible-core 2.19.4 on its own side)
          # via #delegate_to_jinja_filter, the same single-table
          # direction the already-delegated names (combine, lists_mergeby,
          # dict2items, and since the Phase-3 slice below, items2dict)
          # resolved. Behavior contract is
          # unchanged and still enforced by test/unit/filter_engine_test.cr:
          # insertion order, kwarg overrides, empty list for a non-dict
          # input, and undefined-input rejection handled upstream by
          # Krikri.undefined_filter_chain_source (the strict-undefined
          # entry points fire before any filter - including this one -
          # ever sees the value).
          key_name = parse_kwarg(filter_args, "key_name") || "key"
          value_name = parse_kwarg(filter_args, "value_name") || "value"
          delegate_to_jinja_filter(
            "dict2items", value,
            {"key_name" => key_name, "value_name" => value_name},
          )
        when "items2dict"
          # items2dict(key_name='key', value_name='value') - the inverse
          # of dict2items: takes a list of dicts (each having a `key_name`
          # field and a `value_name` field) and produces a single dict
          # mapping key_name -> value_name. Ansible's own filter,
          # same Python-ansible-only status.
          #
          # Phase-3 consolidation slice #1: the hand-rolled JSON::Any
          # copy this dispatch used to run (#items_to_dict) is deleted -
          # the name now routes through the ONE native
          # `Crinja.filter(:items2dict)` registration (jinja_filters.cr)
          # via #delegate_to_jinja_filter, the same pilot shape as
          # dict2items. A probe battery comparing the two copies
          # found them identical on 17 of 19 cases and found
          # BOTH divergences in the hand-rolled copy's disfavor when
          # arbitrated against ansible-core 2.19.11: a non-string
          # key (`{'key': 1}`) must stringify (Ansible renders
          # `{"1": "x"}`; the hand-rolled copy silently skipped it) and
          # a null input must raise (Ansible: "items2dict requires
          # a list, got NoneType instead"; the hand-rolled copy
          # silently returned `{}`). The silent skip of non-dict or
          # missing-field elements (stricter in Ansible 2.19, which
          # raises) is the shared, spec-locked krikri contract on both
          # sides and is preserved unchanged - both engines deliberately
          # tolerate a malformed element rather than fail the whole
          # filter (test/unit/filter_engine_test.cr). Undefined-input
          # rejection still happens upstream in
          # Krikri.undefined_filter_chain_source, before any filter runs.
          key_name = parse_kwarg(filter_args, "key_name") || "key"
          value_name = parse_kwarg(filter_args, "value_name") || "value"
          delegate_to_jinja_filter(
            "items2dict", value,
            {"key_name" => key_name, "value_name" => value_name},
          )
        when "regex_search"
          # regex_search(pattern, group_ref='') - Ansible's own
          # filter (not standard Jinja2): searches *pattern* anywhere in
          # value (Python re.search, not a full match). No match at all
          # resolves to Python None/JSON null - matching Ansible
          # exactly (it returns None, NOT undefined), so a downstream
          # `is not none` test sees the miss (buluma.cve_2024_3094's own
          # list-form failed_when gates on exactly that, round 189) and
          # `| default(...)` without a truthy second arg does NOT fire,
          # same as Jinja. A caller chaining `| first` on a no-match
          # fails the way Ansible's `None | first` does, instead of
          # silently succeeding on bogus data. Found via konstruktoid-
          # hardening's own `sshd_version.stderr_lines |
          # regex_search('OpenSSH_(...)', '\\1') | first` (extracting the
          # installed OpenSSH version) - previously unimplemented and
          # falling through to the `else` passthrough below, returning
          # `sshd_version.stderr_lines` *itself* unfiltered as "the
          # version", which downstream `is version(...)` comparisons then
          # read nonsense out of.
          # Phase-3 slice 3: the semantics (group-ref grammar, the
          # always-a-list group_ref return, no-match -> null, the
          # multiline/ignorecase kwargs) now live in the SHARED
          # FilterCore.regex_search core that the Crinja-side
          # registration (jinja_filters.cr) calls too - previously TWO
          # independently-maintained copies that had each found and
          # fixed the group_ref bugs separately (see FilterCore's
          # comment for the full arbitrated contract). Ansible
          # takes multiline/ignorecase as kwargs, so kwarg-shaped args
          # are excluded from the positional group-ref slot here.
          args = split_top_level_args(filter_args)
          positional = args.reject { |arg| arg.strip.match(/^(multiline|ignorecase)\s*=/) }
          pattern = positional[0]?.try { |arg| as_string(resolve_expression(arg)) } || ""
          group_ref = positional[1]?.try { |arg| as_string(resolve_expression(arg)) }
          options = Regex::Options::None
          if kw = parse_kwarg_expr(filter_args, "multiline")
            # Python re.M only moves ^/$ to line boundaries - NOT
            # dot-matches-newline. Crystal's MULTILINE implies DOTALL
            # (Ruby semantics), so a pattern like 'Version:\\ .*:([\\d.]+)'
            # swallowed everything through to the next line and matched
            # an unrelated later line's capture (pluggero.openssh round
            # 981024: Version: 1:8.9p1... vs the Description's
            # "compat:1.1.4" line) - MULTILINE_ONLY is the
            # Python-equivalent flag.
            options |= Regex::Options::MULTILINE_ONLY if truthy?(kw)
          end
          if kw = parse_kwarg_expr(filter_args, "ignorecase")
            options |= Regex::Options::IGNORE_CASE if truthy?(kw)
          end

          case result = FilterCore.regex_search(as_string(value), pattern, group_ref, options)
          when String
            JSON::Any.new(result)
          when Array
            JSON::Any.new(result.map { |captured| JSON::Any.new(captured) })
          else
            JSON::Any.new(nil)
          end
        when "regex_findall"
          # regex_findall(pattern, multiline=False, ignorecase=False) -
          # Ansible's own filter (Python re.findall): every non-
          # overlapping match; with capture groups each match is a list of
          # that match's group strings (exactly ONE group -> flat scalars,
          # Python's own single-group return shape). Needed on the
          # hand-rolled side since a bare `{{ }}` filter-name
          # `map('regex_findall', ...)` chain goes through THIS plain
          # evaluator, not Crinja (only `{%`/`{#` block-tag escalation
          # reaches Crinja's filters). Real bug found live-verifying
          # prometheus.prometheus.node_exporter: its own _common role's
          # checksum-file parsing (`raw.splitlines() | map('regex_
          # findall', '^([a-fA-F0-9]+)\\s+(.+)$') | ...`) silently no-
          # op'd (each line passed through unchanged instead of being
          # split into [checksum, filename]) - the whole checksum dict
          # ended up empty, failing every download's checksum check.
          # Phase-3 slice 3: the match-shaping lives in the SHARED
          # FilterCore.regex_findall core that the Crinja-side
          # registration (jinja_filters.cr) calls too - the `mat.size`
          # single-capture-group bug this fixes was historically fixed
          # separately in each copy. Ansible accepts
          # multiline/ignorecase both positionally (in that order) and
          # as named kwargs; the named form previously only worked on
          # the Crinja side.
          args = split_top_level_args(filter_args)
          positional = args.reject { |arg| arg.strip.match(/^(multiline|ignorecase)\s*=/) }
          pattern = positional[0]?.try { |arg| as_string(resolve_expression(arg)) } || ""
          options = Regex::Options::None
          if truthy_arg?(parse_kwarg_expr(filter_args, "multiline"), positional[1]?)
            # Same Python-re.M-not-DOTALL rule as regex_search above:
            # Crystal's MULTILINE wrongly implies DOTALL.
            options |= Regex::Options::MULTILINE_ONLY
          end
          if truthy_arg?(parse_kwarg_expr(filter_args, "ignorecase"), positional[2]?)
            options |= Regex::Options::IGNORE_CASE
          end

          JSON::Any.new(FilterCore.regex_findall(as_string(value), pattern, options).map do |entry|
            entry.is_a?(String) ? JSON::Any.new(entry) : JSON::Any.new(entry.map { |group| JSON::Any.new(group) })
          end)
        when "regex_replace"
          # regex_replace(pattern, replacement='') - Ansible's own
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
          # Ansible's regex_replace(value, pattern, replacement,
          # ignorecase, multiline) accepts the flags both positionally (in
          # that order) and as named kwargs (named wins) - same shape as
          # regex_findall above. The flags were previously dropped
          # entirely here.
          positional = args.reject { |arg| arg.strip.match(/^(multiline|ignorecase)\s*=/) }
          pattern = positional[0]?.try { |arg| as_string(resolve_expression(arg)) } || ""
          replacement = positional[1]?.try { |arg| as_string(resolve_expression(arg)) } || ""
          options = Regex::Options::None
          if truthy_arg?(parse_kwarg_expr(filter_args, "ignorecase"), positional[2]?)
            options |= Regex::Options::IGNORE_CASE
          end
          if truthy_arg?(parse_kwarg_expr(filter_args, "multiline"), positional[3]?)
            # Python re.M only moves ^/$ to line boundaries - NOT
            # dot-matches-newline; Crystal's MULTILINE implies DOTALL
            # (Ruby semantics), so MULTILINE_ONLY is the
            # Python-equivalent flag (same rule as regex_search above).
            options |= Regex::Options::MULTILINE_ONLY
          end

          JSON::Any.new(FilterCore.regex_replace(as_string(value), pattern, replacement, options))
        when "hash"
          # hash(algorithm='sha1') - Ansible's own filter
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
          JSON::Any.new(FilterCore.hash(as_string(value), algorithm))
        when "password_hash"
          # password_hash(hashtype='sha512', salt=None, rounds=None) -
          # Ansible's own filter (passlib-backed), a salted crypt(3)
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
          explicit_salt = args[1]?.try { |arg| as_string(resolve_expression(arg)) }
          JSON::Any.new(FilterCore.password_hash(as_string(value), hashtype, explicit_salt))
        when "type_debug"
          # type_debug - Ansible/Jinja2's own filter, returns
          # Python's type name for the value (matching `type(x).
          # __name__`) - used almost exclusively in role assert.yml
          # sanity checks (`my_list | type_debug == "list"`). Entirely
          # unimplemented - fell through to the unknown-filter
          # passthrough, returning the value's own rendered string
          # instead of a type name, so every one of these asserts failed
          # outright regardless of the actual (correct) variable type.
          # Found via robertdebock.httpd's own assert.yml (round 19).
          JSON::Any.new(FilterCore.type_debug(value))
        when "to_json"
          # to_json(**kwargs) - Ansible's own filter, wraps Python's
          # json.dumps() (default ", "/": " item/key separators, not
          # Crystal's own compact JSON::Any#to_json) - added here too on
          # the usual "check both evaluators" rule, matching the Crinja-
          # side copy added for the same gap found via geerlingguy.
          # logstash's own 30-elasticsearch-output.conf.j2 (a `.j2`
          # template file, reaching Crinja not this evaluator).
          JSON::Any.new(FilterCore.to_json(strict_render_deferred_leaves(value)))
        when "b64encode"
          # b64encode(encoding='utf-8') - Ansible's own filter,
          # standard base64 (not urlsafe). Entirely unimplemented before
          # - a bare `{{ }}` task param using it (as opposed to the same
          # filter reaching Crinja via a `.j2` file, already registered
          # separately in jinja_filters.cr) fell through to the
          # unknown-filter passthrough, silently returning the plaintext
          # value unencoded.
          JSON::Any.new(FilterCore.b64encode(as_string(value)))
        when "b64decode"
          # b64decode() - inverse of the above. Ansible raises on
          # invalid input rather than silently passing it through;
          # matched here via Base64's own DecodeError.
          JSON::Any.new(FilterCore.b64decode(as_string(value)))
        when "from_json"
          # from_json() - Ansible's own filter, parses a JSON
          # string value into a real structure (the mirror of to_json
          # above) - commonly used on a registered command/uri result's
          # own stdout/content ("{{ result.stdout | from_json }}").
          FilterCore.from_json(as_string(value))
        when "from_yaml"
          # from_yaml() - Ansible's own filter, parses a YAML
          # string into a real structure. Converts via YAML.parse ->
          # to_json -> JSON.parse (YAML's Any and JSON::Any aren't the
          # same type in Crystal) rather than hand-rolling a converter.
          FilterCore.from_yaml(value)
        when "json_query"
          # json_query(expr) - Ansible's own filter (from
          # `community.general`, commonly reachable as a bare name), a
          # full JMESPath query over the value. Found unimplemented via
          # itigoag.packages' own `packages_var_lower |
          # json_query(packages_var_query)` task.
          #
          # Phase-1 consolidation (filter #3) routed this through
          # delegate_to_jinja_filter so both paths shared the ONE
          # `Crinja.filter(:json_query)` registration - but the
          # delegation's own inbound/outbound JSON::Any <-> Crinja::Value
          # bridge, plus the registration body's internal round-trip back
          # to JSON::Any for the JMESPath engine, made this path pay four
          # tree conversions per call for a filter whose engine
          # (src/krikri/jmespath.cr) is already JSON::Any-native. The {{ }}
          # path therefore dispatches DIRECTLY to
          # Krikri::JMESPath.evaluate_json_query (zero conversions - the
          # error wrapping lives in that shared wrapper, so the
          # invalid-expression text still has exactly one source), while
          # the Crinja-side registration remains for real .j2 templates,
          # whose Crinja::Value target must be bridged regardless.
          #
          # The expression is passed as the raw parsed text (NOT
          # #resolve_expression) to match the old hand-rolled behavior
          # exactly: a quoted literal is unwrapped, but a bare variable
          # name reaches the JMESPath engine verbatim. The
          # missing-expression guard stays here (a Crinja vararg is a
          # truthy value even when empty-string). Behavior contract
          # unchanged and still enforced by test/unit/jmespath_test.cr
          # (both engines' happy paths plus the invalid-expression task
          # failure).
          expr = parse_filter_arg(filter_args)
          raise "json_query: missing JMESPath expression" if expr.empty?
          Krikri::JMESPath.evaluate_json_query(expr, value)
        when "to_yaml"
          # to_yaml(**kwargs) - Ansible's own filter, a YAML dump
          # (real PyYAML default: block style, keys sorted). Converts
          # via value.to_json -> YAML.parse -> to_yaml (JSON is a valid
          # YAML flow-syntax subset, round-trips cleanly through
          # Crystal's own YAML formatter) - same approach the Crinja-
          # side to_nice_yaml filter already uses, mirrored here for the
          # plain `{{ }}` evaluator. Unlike to_nice_yaml, doesn't accept
          # indent=/sort_keys= overrides - matches Ansible, where
          # to_yaml (unlike to_nice_yaml) takes no such kwargs of its
          # own beyond the underlying yaml.dump()'s already-implied
          # defaults.
          JSON::Any.new(FilterCore.to_yaml(strict_render_deferred_leaves(value)))
        when "checksum"
          # checksum() - Ansible's own filter (ansible.plugins.
          # filter.core), a plain sha1 hex digest - distinct from the
          # general-purpose `hash(algorithm=...)` filter above (which
          # defaults to sha1 too, but accepts other algorithms);
          # checksum specifically always means sha1, matching Ansible's
          # own hard-coded `hashlib.sha1(...)`.
          JSON::Any.new(FilterCore.checksum(as_string(value)))
        when "union"
          # union(other) - Ansible's own filter, set union
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
          JSON::Any.new(FilterCore.union(value.as_a? || [] of JSON::Any, other.as_a? || [] of JSON::Any))
        when "path_join"
          # path_join(list) - Ansible filter: joins a list of path
          # components with os.path.join semantics (an absolute
          # component resets the accumulated path rather than appending
          # to it - Crystal's own File.join has no such reset).
          parts = as_array(value).compact_map(&.as_s?)
          JSON::Any.new(FilterCore.path_join(parts))
        when "splitext"
          # splitext() - Ansible filter, mirrors Python's
          # os.path.splitext: [root, ext] (ext includes the leading '.',
          # empty string if there's no extension).
          root, ext = FilterCore.splitext(as_string(value))
          JSON::Any.new([JSON::Any.new(root), JSON::Any.new(ext)])
        when "urldecode"
          # urldecode() - Ansible filter, percent-decodes a URL-
          # encoded string.
          JSON::Any.new(FilterCore.urldecode(as_string(value)))
        when "urlsplit"
          # urlsplit(query='') - Ansible filter: parses value as a
          # URL. With no argument, returns the full breakdown dict; with
          # a component name argument, returns just that component as a
          # string (empty string if absent) - matches Ansible's own
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
          # zip(*others)/zip_longest(*others, fillvalue=None) -
          # Ansible filters, Python's own zip()/itertools.zip_longest().
          #
          # Phase-3 consolidation slice #5: the hand-rolled N-way zip this
          # dispatch used to run is retired - the name routes through the
          # ONE native Crinja.filter registration (jinja_filters.cr) via
          # #delegate_to_jinja_filter. The lists go through as varargs and
          # fillvalue= as a real kwarg, matching ansible-core 2.19
          # (live-verified: every positional argument is another LIST -
          # `zip_longest([3], '-')` zips three lists with null padding, it
          # never sets the fill). The delegated registration also un-caps
          # this at 3-way zip, which the Crinja template side's old
          # declared-kwarg shape silently was.
          positional, kwargs = split_positional_and_kwargs(filter_args, ["fillvalue"])
          delegate_to_jinja_filter(filter_name, value, kwargs, positional)
        when "product"
          # product(*others) - Ansible filter, Python's own
          # itertools.product(): Cartesian product of value and every
          # other list argument, each result row a list.
          #
          # Phase-3 consolidation slice #5: hand-rolled copy retired for
          # the ONE native Crinja.filter(:product) registration via
          # #delegate_to_jinja_filter, same all-positional N-way shape
          # as zip above.
          positional, kwargs = split_positional_and_kwargs(filter_args)
          delegate_to_jinja_filter("product", value, kwargs, positional)
        when "regex_escape"
          # regex_escape(re_type='python') - Ansible filter, escapes
          # regex special characters so the value can be embedded
          # literally into a larger pattern.
          JSON::Any.new(FilterCore.regex_escape(as_string(value)))
        when "to_nice_json"
          # to_nice_json(indent=4, sort_keys=True) - Ansible filter,
          # a pretty-printed JSON dump (the mirror of to_nice_yaml).
          # Real to_nice_json is json.dumps(indent=4, sort_keys=True) -
          # 4-space indent. Crystal's own JSON::Any#to_pretty_json takes
          # an indent parameter, so pass 4 spaces rather than hand-rolling
          # an emitter (the old 2-space output diverged byte-for-byte from
          # Ansible, found live via modules_data.yml's nested-report
          # byte-diff). Same scope limit to_nice_yaml's own indent=
          # already documents.
          sort_keys = (kw = parse_kwarg_expr(filter_args, "sort_keys")) ? truthy?(kw) : true
          JSON::Any.new(JSON.parse(FilterCore.to_nice_json(strict_render_deferred_leaves(value), sort_keys)).to_pretty_json(indent: "    "))
        when "to_nice_yaml"
          # to_nice_yaml(indent=N, sort_keys=True) - Ansible filter.
          # NOT implemented natively here: the serializer itself is the
          # Crinja-side registration (jinja_filters.cr's own
          # `Crinja.filter(:to_nice_yaml)`), delegated to below so the one
          # YAML emitter keeps one owner - indent= is ignored either way
          # (Crystal's YAML::Builder has no configurable indent width,
          # see that registration's own comment).
          #
          # This case had to appear here once the chain head grew lazy-leaf
          # deferral (see #strict_render_deferred_leaves): before, a
          # poisoned container (`my_config: {foo: {bar: "{{ undef_var }}"}}`
          # fed through `{{ my_config | to_nice_yaml }}`) died in the head
          # render - either Crinja's context conversion or this engine's -
          # with "'x' is undefined", and the dispatch never being reached
          # didn't matter. With the head deferring, the chain falls through
          # to this dispatch, where an unknown-filter error would have
          # replaced the real undefined-name message (caught by
          # test/unit/nested_container_undefined_filter_test.cr). The
          # strict re-render below restores fail-on-access, matching
          # Ansible for a serializer that reads every leaf.
          sort_keys = (kw = parse_kwarg_expr(filter_args, "sort_keys")) ? truthy?(kw) : true
          kwargs = Hash(String, JSON::Any).new
          kwargs["sort_keys"] = JSON::Any.new(sort_keys)
          delegate_to_jinja_filter("to_nice_yaml", strict_render_deferred_leaves(value), kwargs)
        when "human_readable"
          # human_readable(isbits=False, unit=None) - Ansible
          # filter, formats a byte count as e.g. "1.00 KB" (1024-based).
          bytes = value.as_i64? || value.as_f?.try(&.to_i64) || 0_i64
          isbits = (kw = parse_kwarg_expr(filter_args, "isbits")) ? truthy?(kw) : false
          JSON::Any.new(FilterCore.format_human_readable(bytes, isbits))
        when "human_to_bytes"
          # human_to_bytes(default_unit=None, isbits=False) -
          # Ansible filter, the inverse of human_readable: parses
          # "10GB"/"1.5 MB" etc back into a raw byte count.
          JSON::Any.new(FilterCore.parse_human_to_bytes(as_string(value)))
        when "netmask_to_cidr"
          # community.general filter: dotted-decimal subnet mask ->
          # CIDR prefix length int (e.g. "255.255.255.0" -> 24). Found
          # via kyl191.openvpn's own openvpn_server_netmask_cidr default.
          JSON::Any.new(FilterCore.netmask_to_cidr(as_string(value)).to_i64)
        when "md5"
          JSON::Any.new(FilterCore.md5(as_string(value)))
        when "sha1"
          JSON::Any.new(FilterCore.sha1(as_string(value)))
        when "expanduser"
          # expanduser() - Ansible filter, mirrors Python's
          # os.path.expanduser: a leading `~` (or `~user`, not
          # supported here - only the current-user shorthand) expands
          # to $HOME.
          JSON::Any.new(FilterCore.expanduser(as_string(value)))
        when "expandvars"
          # expandvars() - Ansible filter, mirrors Python's
          # os.path.expandvars: `$VAR`/`${VAR}` references replaced from
          # the CONTROLLER's own environment (unset -> left as-is,
          # matching Python's own behavior).
          JSON::Any.new(FilterCore.expandvars(as_string(value)))
        when "normpath"
          # normpath() - Ansible filter, mirrors Python's
          # os.path.normpath: collapses `.`/`..`/redundant `/` without
          # making the path absolute (relative stays relative).
          JSON::Any.new(FilterCore.normpath(as_string(value)))
        when "relpath"
          # relpath(start='.') - Ansible filter, mirrors Python's
          # os.path.relpath: value expressed relative to *start*.
          #
          # Phase-3 consolidation slice #5: hand-rolled copy retired for
          # the ONE native Crinja.filter(:relpath) registration via
          # #delegate_to_jinja_filter. start= is passed as a real kwarg
          # (live-verified against ansible-core 2.19: the kwarg form
          # is accepted there) - the old positional-only parse silently
          # treated `relpath(start='/a')`'s whole `start='/a'` text as
          # the start path.
          positional, kwargs = split_positional_and_kwargs(filter_args, ["start"])
          delegate_to_jinja_filter("relpath", value, kwargs, positional)
        when "commonpath"
          # commonpath() - Ansible filter, mirrors Python's
          # os.path.commonpath: the longest common directory prefix of
          # value (a list of paths).
          paths = as_array(value).compact_map(&.as_s?)
          JSON::Any.new(FilterCore.commonpath(paths))
        when "log"
          # log(base=math.e) - Ansible filter: natural log with no
          # argument, log base *base* otherwise.
          #
          # Phase-3 consolidation slice #5: hand-rolled copy retired for
          # the ONE native Crinja.filter(:log) registration via
          # #delegate_to_jinja_filter. base= is a real kwarg in
          # ansible (live-verified `8 | log(base=2)` -> 3.0); the old
          # positional-only parse turned that exact form into a natural
          # log by failing to resolve `base=2` as a number.
          positional, kwargs = split_positional_and_kwargs(filter_args, ["base"])
          delegate_to_jinja_filter("log", value, kwargs, positional)
        when "pow"
          # pow(x) - Ansible filter: value raised to the power x.
          #
          # Phase-3 consolidation slice #5: hand-rolled copy retired for
          # the ONE native Crinja.filter(:pow) registration via
          # #delegate_to_jinja_filter. Ansible's own parameter is
          # positional-only (`power(x, y)` - live-verified that
          # `pow(x=10)`/`pow(exponent=10)` both fail there), so only the
          # positional shape is fed through as a vararg.
          positional, kwargs = split_positional_and_kwargs(filter_args)
          delegate_to_jinja_filter("pow", value, kwargs, positional)
        when "to_uuid"
          # to_uuid(namespace=ANSIBLE_NAMESPACE) - Ansible filter, a
          # deterministic UUID5 (SHA1-based) - same input always
          # produces the same UUID. Ansible's own default namespace
          # ('361E6D51-FAEC-444A-9079-341386DA8E2E'), not the standard
          # DNS namespace real uuid5() implementations default to.
          # Positional or keyword (`to_uuid(x, ns)` / `to_uuid(x,
          # namespace=ns)` - real filter_plugin's plain second parameter).
          positional, kwargs = split_positional_and_kwargs(filter_args, ["namespace"])
          namespace = as_string(kwargs["namespace"]? || positional[0]? || JSON::Any.new("361E6D51-FAEC-444A-9079-341386DA8E2E"))
          JSON::Any.new(FilterCore.to_uuid(as_string(value), namespace))
        when "symmetric_difference"
          # symmetric_difference(other) - Ansible filter: elements
          # in exactly one of value/other, not both.
          other = resolve_expression(filter_args)
          JSON::Any.new(FilterCore.symmetric_difference(value.as_a? || [] of JSON::Any, other.as_a? || [] of JSON::Any))
        when "combinations"
          # combinations(n) - Ansible filter, Python's own
          # itertools.combinations(value, n): every n-length combination
          # (order-independent, no repeats) of value's own elements.
          #
          # Phase-3 consolidation slice #5: the hand-rolled copy (and its
          # private #combinations helper) is retired for the ONE native
          # Crinja.filter(:combinations) registration via
          # #delegate_to_jinja_filter. n keeps its krikri default of 2
          # on both engines (real itertools.combinations REQUIRES r -
          # live-verified "missing required argument 'r' (pos 2)"; the
          # shared default is a deliberate, spec-locked divergence).
          positional, kwargs = split_positional_and_kwargs(filter_args, ["n"])
          delegate_to_jinja_filter("combinations", value, kwargs, positional)
        when "permutations"
          # permutations(n=None) - Ansible filter, Python's own
          # itertools.permutations(value, n): every n-length ordered
          # arrangement (defaults to the full length of value).
          #
          # Phase-3 consolidation slice #5: hand-rolled copy (and its
          # private #permutations helper) retired for the ONE native
          # Crinja.filter(:permutations) registration via
          # #delegate_to_jinja_filter, same shape as combinations above.
          positional, kwargs = split_positional_and_kwargs(filter_args, ["n"])
          delegate_to_jinja_filter("permutations", value, kwargs, positional)
        when "rekey_on_member"
          # rekey_on_member(member, duplicates='error') - Ansible
          # filter: converts a list of dicts into a dict keyed by each
          # element's own `member` field value.
          #
          # Phase-3 consolidation slice #5: the hand-rolled copy is
          # retired for the ONE native Crinja.filter(:rekey_on_member)
          # registration via #delegate_to_jinja_filter. Two arbitrated
          # fixes come with the bridge, both live-verified against
          # ansible-core 2.19.11: a NON-STRING member value (e.g. a
          # numeric id) is stringified into the key (`{"id":5}` rekeys
          # to `"5"` there; the old copy silently skipped the item), and
          # `duplicates=` is a real kwarg there (the old copy only read
          # it positionally). `warn` still behaves as `overwrite` (no
          # separate warning channel), on both engines.
          positional, kwargs = split_positional_and_kwargs(filter_args, ["member", "duplicates"])
          delegate_to_jinja_filter("rekey_on_member", value, kwargs, positional)
        when "extract"
          # extract(container, morekeys=None) - Ansible filter:
          # value is used as an index/key into *container* (commonly
          # piped from `map('extract', container)` over a list of
          # indices/keys); `morekeys` (a further key, or list of keys)
          # drills down into the extracted element.
          #
          # Ansible/Jinja raises when the key is absent from a
          # hash container (e.g. `map('extract', hostvars,
          # 'ansible_host')` with no host carrying `ansible_host`
          # aborts the play with "has no attribute") - a silent nil
          # here changes control flow by letting bad-inventory
          # playbooks run on. Found in dirless-infra's test-backend.yml
          # (commits 21077616/e7e1102d); the raise now lives in the
          # SHARED FilterCore.extract core that the Crinja-side
          # registration (jinja_filters.cr) calls too - previously TWO
          # independently-maintained copies that 21077616 had to fix in
          # the same commit, and whose miss wording had already
          # diverged (this copy said "extract: key 'x' not found" for a
          # plain dict's first-level miss and labeled every non-dict
          # node 'dict'; Ansible's uniform getitem wording, now
          # shared, is arbitrated in FilterCore's comment).
          #
          # Hostvars detection stays hoisted HERE (this engine has no
          # HostVarsVarsDict wrapper - its hostvars is the plain JSON
          # hash @vars carries): container object identity with
          # @vars["hostvars"] supplies the "HostVarsVars" miss label
          # the core uses at every level under it, matching
          # Ansible's wrapper-typed per-host dicts.
          args = split_top_level_args(filter_args)
          container = args[0]?.try { |arg| resolve_expression(arg) }
          return JSON::Any.new(nil) unless container

          hostvars_label = nil
          if (vars = @vars) && (hostvars_var = vars["hostvars"]?) &&
             (hostvars_raw = hostvars_var.raw).is_a?(Hash) &&
             (container_raw_check = container.raw).is_a?(Hash) &&
             container_raw_check.same?(hostvars_raw)
            hostvars_label = "HostVarsVars"
          end
          keys = [value]
          if morekeys_arg = args[1]?
            morekeys = resolve_expression(morekeys_arg)
            # A null morekeys is Ansible's None: absent, not a
            # key (live-verified: `x | extract(mapping, none)` ->
            # mapping[x]).
            unless morekeys.raw.nil?
              morekeys.as_a? ? keys.concat(morekeys.as_a) : keys << morekeys
            end
          end
          extracted = FilterCore.extract(container, keys, hostvars_label)
          # The container is the hostvars magic: the walked value belongs
          # to the host named by the FIRST key (`map('extract', hostvars,
          # 'who')` over a host-name list, `x | extract(hostvars, 'attr')`)
          # and re-renders in THAT host's scope, not the reading host's -
          # the same HostVarsVars semantics the direct `hostvars[h].attr`
          # lookups get. Hostile stored text stays gated (the value-level
          # registry), as does the whole chain when its root is an
          # execution-resolved value.
          attr_key = keys[1]?.try(&.as_s?)
          if hostvars_label && !chain_root_unsafe? &&
             (host = keys[0]?.try(&.as_s?)) &&
             (host_subs = HostvarsContext.substitutor_for?(host, @vars)) &&
             !(attr_key && VarSubstitutor.resolved_var_name?(host, attr_key))
            extracted = JinjaRenderer.rerender_nested_templates(extracted, host_subs)
          end
          extracted
        when "from_yaml_all"
          # from_yaml_all() - Ansible filter: parses a multi-
          # document YAML string (`---`-separated) into a list of parsed
          # documents.
          #
          # Phase-3 consolidation slice #5: the hand-rolled copy is
          # retired for the ONE native Crinja.filter(:from_yaml_all)
          # registration via #delegate_to_jinja_filter. Invalid YAML
          # fails the task on both engines either way (live-verified
          # against ansible-core 2.19.11); the raised message is
          # now the underlying YAML parse error rather than this
          # dispatch's own generic label - same outcome, truer text.
          delegate_to_jinja_filter("from_yaml_all", value, Hash(String, JSON::Any).new)
        when "vault"
          # vault(secret, vault_id=None, salt=None) - Ansible
          # filter: encrypts value into ansible-vault ciphertext text
          # using *secret* as the vault password (an explicit filter
          # argument, NOT the session-wide --vault-password-file/
          # --ask-vault-pass secret Vault.password holds -
          # Ansible's own vault filter takes its own key this way too).
          args = split_top_level_args(filter_args)
          secret = args[0]?.try { |arg| as_string(resolve_expression(arg)) } || ""
          JSON::Any.new(Vault.encrypt(as_string(value), secret))
        when "unvault"
          # unvault(secret) - Ansible filter, the inverse of vault
          # above: decrypts an ansible-vault ciphertext string using
          # *secret* as the password.
          args = split_top_level_args(filter_args)
          secret = args[0]?.try { |arg| as_string(resolve_expression(arg)) } || ""
          JSON::Any.new(Vault.decrypt(as_string(value), secret))
        when "format"
          # format(*args, **kwargs) - jinja2's own printf-style filter
          # (the name Ansible exposes it under too): `'%s-%s' | format(a, b)`
          # and `'%(v)s' | format(v=x)`. This plain `{{ }}` evaluator never
          # had it, so a task-arg like manala.ngrok's unarchive
          # `src: "...ngrok-%(version)s..." | format(version=...)` hard-failed
          # with "No filter named 'format'." while ansible-playbook rendered
          # the URL. Delegates to the ONE implementation (krikri-jinja's
          # py_format), which owns the positional-tuple and keyword-mapping
          # operands and CPython's error wording for both.
          positional, kwargs = split_positional_and_kwargs(filter_args, any_kwarg: true)
          begin
            delegate_to_jinja_filter("format", value, kwargs, positional)
          rescue ex : KrikriJinja::TemplateError
            # A filter that RAN and raised is Ansible's own filter-plugin
            # failure, not a syntax/unknown-filter error: 2.19.11 reports
            # `Error while resolving value for 'msg': The filter plugin
            # 'ansible.builtin.format' failed: 'missing'` (live-verified),
            # which is the FilterPluginError finalization chain below -
            # raw_message drops the engine's own "line N: " prefix, which
            # Ansible's wording never carries.
            cause = ex.raw_message
            raise Krikri::FilterPluginError.new(
              "The filter plugin 'ansible.builtin.format' failed: #{cause}", cause)
          end
        when "ternary"
          # ternary(true_val, false_val) - Ansible's own filter
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
          #
          # Phase-3 consolidation slice #2: the hand-rolled JSON::Any
          # pick-a-branch copy this dispatch used to run is deleted -
          # the name now routes through the ONE native
          # `Crinja.filter(:ternary)` registration (jinja_filters.cr)
          # via #delegate_to_jinja_filter. The bare-`omit` sentinel
          # handling that was this branch's own load-bearing behavior
          # (the survey's flagged risk for this slice) survives as the
          # pre-resolution mapping below: a bare `omit` argument text
          # becomes OMIT_SENTINEL *before* delegation (resolving it as a
          # variable would yield null - #resolve_base_expression has no
          # `omit` concept - and the registration passes its arguments
          # through untouched, so the sentinel string then flows out
          # exactly like Ansible's omit object and is stripped by
          # the same substitute_task_params contract as before).
          # A probe battery comparing the two copies found them
          # identical on 19 of 24 cases and three
          # divergences, all arbitrated against ansible-core
          # 2.19.11 and all fixed in the old copy's disfavor: the string
          # conditions "0"/"false"/"False" are TRUTHY (Python bool() on
          # a non-empty string - the old copy's truthy? treated them as
          # falsy and picked the wrong branch), a missing true_val/
          # false_val argument now raises like Ansible's Python
          # signature check (the old copy silently returned null), and
          # the optional third (none_val) argument is honored for a null
          # condition (both old copies silently ignored it). Both
          # arguments are now resolved eagerly instead of only the
          # chosen one - Jinja evaluates call arguments eagerly
          # too, and this engine's lenient resolution of an unchosen
          # undefined variable (null) keeps the picked branch identical.
          args = split_top_level_args(filter_args).reject { |arg| arg.strip.empty? }
          varargs = args.map do |arg|
            stripped = arg.strip
            stripped == "omit" ? JSON::Any.new(OMIT_SENTINEL) : resolve_expression(stripped)
          end
          delegate_to_jinja_filter("ternary", value, Hash(String, JSON::Any).new, varargs)
        when "intersect"
          # intersect(other) - Ansible's own filter (ansible.builtin,
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
          JSON::Any.new(FilterCore.intersect(as_array(value), as_array(resolve_expression(filter_args))))
        when "difference"
          # difference(other) - Ansible's own filter: elements of
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
          JSON::Any.new(FilterCore.difference(as_array(value), as_array(resolve_expression(filter_args))))
        when "ipaddr", "ipwrap", "ipv4", "ipv6", "ipsubnet", "ipmath",
             "next_nth_usable", "previous_nth_usable",
             "network_in_network", "network_in_usable", "ip4_hex"
          # ansible.utils ipaddr family - shared core in ipaddr_core.cr,
          # mirrored against ansible-core 2.19.4 + ansible.utils +
          # netaddr 1.3.0 (every query probed live). Also registered on
          # the Crinja side (jinja_filters.cr) so `.j2` template files
          # and `{% %}` blocks resolve the same names.
          args = split_top_level_args(filter_args)
          case filter_name
          when "ipaddr"
            IpAddrCore.ipaddr(value, resolved_query_arg(args[0]?))
          when "ipwrap"
            IpAddrCore.ipwrap(value, resolved_query_arg(args[0]?))
          when "ipv4"
            IpAddrCore.ipaddr(value, resolved_query_arg(args[0]?), 4, "ipv4")
          when "ipv6"
            IpAddrCore.ipaddr(value, resolved_query_arg(args[0]?), 6, "ipv6")
          when "ipsubnet"
            IpAddrCore.ipsubnet(value, resolved_query_arg(args[0]?), args[1]?.try { |arg| resolved_query_arg(arg) })
          when "ipmath"
            amount = resolved_int_arg(args[0]?)
            raise IpAddrCore::IpError.new("You must pass an integer for arithmetic; #{args[0]? ? args[0] : ""} is not a valid integer") unless amount
            IpAddrCore.ipmath(value, amount)
          when "next_nth_usable"
            offset = resolved_int_arg(args[0]?)
            raise IpAddrCore::IpError.new("Must pass in an integer") unless offset
            IpAddrCore.next_nth_usable(value, offset)
          when "previous_nth_usable"
            offset = resolved_int_arg(args[0]?)
            raise IpAddrCore::IpError.new("Must pass in an integer") unless offset
            IpAddrCore.previous_nth_usable(value, offset)
          when "network_in_network"
            IpAddrCore.network_in_network(value, resolve_expression(args[0]? || ""))
          when "network_in_usable"
            IpAddrCore.network_in_usable(value, resolve_expression(args[0]? || ""))
          when "ip4_hex"
            IpAddrCore.ip4_hex(value, resolved_query_arg(args[0]?))
          else
            raise UnknownFilterError.new("No filter named '#{filter_name}'.")
          end
        else
          # Unknown filter - Ansible raises ("Syntax error in
          # template: No filter named 'bodsch.core.type'.", verified
          # live) and fails the task; this used to return *value*
          # unchanged, which is silent corruption: a third-party
          # collection's custom filter (bodsch.core.type,
          # bodsch.core.upgrade, ... - the whole no-arbitrary-Python
          # scope cut) left its operand un-filtered, and the downstream
          # `when:`/`set_fact:` built on it then failed with a confusing
          # type error ("Conditional result (True) was derived from
          # value of type 'dict'") instead of naming the unsupported
          # filter. Modules already report "unavailable modules"
          # explicitly; filters now degrade the same clear way.
          #
          # Only reached for a name NEITHER this engine NOR Crinja
          # implements: ExpressionEvaluator tries Crinja first
          # (#render_via_jinja_value) and only falls back here when
          # that raises, so every Crinja-native filter name is resolved
          # before this branch can see it.
          #
          # Before raising, one last chance: a role-local
          # `filter_plugins/*.py` (or playbook-adjacent one) may define
          # the name - Ansible loads those on the controller the
          # same way it loads role-private `library/*.py` modules.
          # Delegated to the controller's own python3 (see
          # PythonFilterRunner); any failure there (no python3, plugin
          # error, an exception inside the filter) falls straight back
          # to the same raise as before, so roles without custom filter
          # plugins behave exactly as they did.
          if custom = try_python_filter(value, filter_name, filter_args)
            custom
          else
            raise UnknownFilterError.new("No filter named '#{filter_name}'.")
          end
        end
      end
    end
  end
end
