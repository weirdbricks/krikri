require "json"
require "time"
require "openssl/digest"
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
        if match = filter_expr.match(/^(\w+)\s*\((.*)\)$/m)
          filter_name = match[1]
          filter_args = match[2]
        else
          filter_name = filter_expr
          filter_args = ""
        end

        case filter_name
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
          if str = value.as_s?
            JSON::Any.new(str.empty? ? nil : str[0].to_s)
          else
            as_array(value).first? || JSON::Any.new(nil)
          end
        when "last"
          if str = value.as_s?
            JSON::Any.new(str.empty? ? nil : str[-1].to_s)
          else
            as_array(value).last? || JSON::Any.new(nil)
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
          if attr = parse_kwarg(filter_args, "attribute")
            JSON::Any.new(as_array(value).map { |item| item.raw.is_a?(Hash) ? (item[attr]? || JSON::Any.new(nil)) : JSON::Any.new(nil) })
          elsif (inner_name = parse_filter_args(filter_args)[0]?)
            inner_args = parse_filter_args(filter_args)[1..].join(", ")
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
