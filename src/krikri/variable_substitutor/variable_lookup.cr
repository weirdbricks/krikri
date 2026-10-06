require "json"
require "../unsafe_values"
require "./expression_evaluator"
require "./jinja_renderer"

module Krikri
  module VariableSubstitutor
    # VariableLookup - Handles all forms of variable access
    # - Simple: {{ myvar }}
    # - Nested: {{ user.name.first }}
    # - Indexed: {{ array[0] }}, {{ dict['key'] }}
    class VariableLookup
      REGEX_METHOD_SPLIT  = /^split\(\s*(['"])(.*)\1\s*\)$/
      REGEX_METHOD_FIND   = /^find\(\s*(['"])(.*)\1\s*\)$/
      REGEX_METHOD_LSTRIP = /^lstrip\(\s*(?:(['"])(.*)\1\s*)?\)$/
      REGEX_METHOD_RSTRIP = /^rstrip\(\s*(?:(['"])(.*)\1\s*)?\)$/
      REGEX_METHOD_STRIP  = /^strip\(\s*(?:(['"])(.*)\1\s*)?\)$/

      @vars : Hash(String, JSON::Any)

      # The host whose hostvars entry the CURRENT resolve is walking
      # within, when it descended through `hostvars[<host>]` - values
      # fetched inside that entry re-render in THAT host's scope (Ansible's HostVarsVars templar), not the reading host's. Scoped
      # per public entry point (save/clear/restore), so one lookup
      # object reused across expressions never leaks one expression's
      # origin into the next; sub-expression resolutions (bracket keys,
      # the resolve_simple/resolve_nested fallback in #resolve_index_key)
      # clear it the same way, since those read the READING host's vars.
      @origin : String? = nil

      def initialize(@vars : Hash(String, JSON::Any))
      end

      # Unsafe gate (see VarSubstitutor.unsafe_root?): a value resolved
      # through an execution-resolved root (registered result / set_fact /
      # fact / loop item) is never re-rendered, no matter how much its text
      # looks like a template - ansible-core marks module results and
      # facts AnsibleUnsafe. Every rerender_if_templated call site here
      # consults this with the expression it resolved FROM.
      private def unsafe_root?(expr : String?) : Bool
        VarSubstitutor.unsafe_root?(@vars, expr)
      end

      # Simple variable lookup
      def simple(name : String) : String
        saved = @origin
        @origin = nil
        begin
          resolve_simple(name.strip).try { |v| format_value(v) } || "undefined"
        ensure
          @origin = saved
        end
      end

      # Nested variable access
      # Example: user.name, config.database.host
      def nested(expr : String) : String
        saved = @origin
        @origin = nil
        begin
          resolve_nested(expr).try { |v| format_value(v) } || "undefined"
        ensure
          @origin = saved
        end
      end

      # Indexed access (array or hash)
      # Example: mylist[0], mydict['key']
      def indexed(expr : String) : String
        saved = @origin
        @origin = nil
        begin
          resolve_indexed(expr).try { |v| format_value(v) } || "undefined"
        ensure
          @origin = saved
        end
      end

      # Resolves any of the three access forms above to its raw JSON::Any
      # value (nil if undefined) rather than a pre-stringified String - used
      # by FilterEngine so a filter chain (`{{ x | sort | join(',') }}`) can
      # carry real array/hash structure from one filter to the next instead
      # of collapsing to a string after every single filter.
      def resolve(expr : String) : JSON::Any?
        saved = @origin
        @origin = nil
        resolve_scoped(expr)
      ensure
        @origin = saved
      end

      private def resolve_scoped(expr : String) : JSON::Any?
        expr = expr.strip
        top_level_bracket = top_level_char_index(expr, '[')
        top_level_paren = top_level_char_index(expr, '(')
        top_level_dot = top_level_char_index(expr, '.')

        # A `[` anywhere in the string (even deep inside a method call's
        # own ARGUMENT, not a genuine top-level index on the base at
        # all) previously always routed here - resolve_indexed's own
        # `expr.index('[')` then found that same nested bracket and cut
        # the "base" off mid-expression at a meaningless point. Real bug
        # found via prometheus.prometheus.node_exporter's own
        # `{'x86_64': 'amd64', ...}.get(ansible_facts['architecture'],
        # ansible_facts['architecture'])` (a dict-literal `.get()` call
        # whose ARGUMENT happens to contain `[...]` indexing, at DEPTH 1
        # inside the call's own parens - top_level_char_index correctly
        # finds no top-level `[` at all here).
        #
        # A genuine top-level `[` that comes BEFORE any top-level `(`
        # (`ansible_facts.getent_passwd[item][4]`, `mylist[0]`) still
        # must route to resolve_indexed - it already correctly delegates
        # a dotted PREFIX to resolve_nested internally (`base_expr.
        # includes?('.') ? resolve_nested(base_expr) : ...`) before
        # walking the bracket suffix; resolve_nested's own parts loop has
        # no notion of a trailing `[...]` suffix on a dotted part at all.
        if top_level_bracket && (!top_level_paren || top_level_bracket < top_level_paren)
          resolve_indexed(expr)
        elsif top_level_dot
          resolve_nested(expr)
        else
          resolve_simple(expr)
        end
      end

      # Depth-aware search for the first TOP-LEVEL occurrence of *char*
      # (outside quotes and outside `(`/`[`/`{` nesting) - used to decide
      # whether the whole expression is itself indexed/dotted at its own
      # top level, as opposed to a nested occurrence buried inside a
      # method call's own argument or a dict/list literal's own content.
      private def top_level_char_index(expr : String, char : Char) : Int32?
        depth = 0
        quote : Char? = nil

        expr.each_char.with_index do |itm, i|
          if q = quote
            quote = nil if itm == q
          elsif itm == '\'' || itm == '"'
            quote = itm
          elsif depth == 0 && itm == char
            # Checked BEFORE the generic bracket-depth adjustment below -
            # when *char* is itself one of "([{"/")]}" (searching for a
            # literal '[' or '(', not just using them for nesting), the
            # depth-adjustment branch would otherwise always intercept it
            # first, incrementing depth without ever reporting "found at
            # top level" - a genuine top-level '[' or '(' would never be
            # returned at all.
            return i
          elsif "([{".includes?(itm)
            depth += 1
          elsif ")]}".includes?(itm)
            depth -= 1
          end
        end

        nil
      end

      # Finds the `]` matching the `[` at *open_pos*, respecting nested
      # `([{`/`)]}` and quoted strings - a plain `suffix.index(']', pos)`
      # (the previous implementation) stops at the FIRST `]`, which for a
      # bracket key that is itself indexed (`k3s_service_handler[ansible_
      # facts['service_mgr']]`, xanmanning.k3s's own service-manager
      # lookup) is the INNER close bracket, truncating the extracted key
      # to the malformed `ansible_facts['service_mgr'` (missing its own
      # closing bracket) and silently missing the whole lookup.
      private def matching_bracket_close(suffix : String, open_pos : Int32) : Int32?
        depth = 0
        quote : Char? = nil

        (open_pos...suffix.size).each do |i|
          itm = suffix[i]
          if q = quote
            quote = nil if itm == q
          elsif itm == '\'' || itm == '"'
            quote = itm
          elsif "([{".includes?(itm)
            depth += 1
          elsif ")]}".includes?(itm)
            depth -= 1
            return i if depth == 0 && itm == ']'
          end
        end

        nil
      end

      # Walks a dotted/indexed suffix (`.stat.exists`, "[0].name",
      # ".days") against an already-resolved value, for a caller that
      # computed the base value itself (ExpressionEvaluator's
      # parenthesized-sub-expression handling: `( a - b ).days` needs to
      # look `.days` up on the *result* of `a - b`, not on some variable
      # named "( a - b )") rather than looking it up from @vars the way
      # resolve/resolve_indexed/resolve_nested always do. An empty suffix
      # returns *start* unchanged.
      def walk(start : JSON::Any, suffix : String) : JSON::Any?
        saved = @origin
        @origin = nil
        walk_scoped(start, suffix)
      ensure
        @origin = saved
      end

      private def walk_scoped(start : JSON::Any, suffix : String) : JSON::Any?
        current = start
        pos = 0

        while pos < suffix.size
          return nil unless current

          case suffix[pos]
          when '.'
            pos += 1
            dot_start = pos
            while pos < suffix.size && suffix[pos] != '.' && suffix[pos] != '['
              pos += 1
            end
            part = suffix[dot_start...pos]
            # Ansible/Jinja2 lets a dotted numeric index chain
            # (`.0.0`) walk arbitrarily deep into nested lists/dicts.
            # This fallback path's own hand-rolled branch below only
            # handled Hash key lookup - unlike the already-correct
            # `apply_dotted_parts` used elsewhere, it had no Array
            # branch at all. Crinja itself handles a single dotted
            # level on a paren-wrapped result, but raises on filters
            # it doesn't implement (like this repo's `regex_findall`),
            # forcing the multi-level chain into `walk` - where a
            # second dotted level silently returned "undefined"
            # instead of indexing into the array. Found in round
            # 813338, role xolyu.mariadb: `( item | regex_findall(...)
            # ).0.0`-style version-string parsing lost `major`/`minor`/
            # `build` to "undefined" (Ansible: "10"/"6"/"12").
            # Delegate to `apply_dotted_parts` so walk gets Hash key
            # lookup, string methods, AND Array numeric-dot-indexing
            # with no duplicated logic; its nil return propagates via
            # the `return nil unless current` check above.
            current = apply_dotted_parts(current, [part])
          when '['
            close = matching_bracket_close(suffix, pos)
            return nil unless close
            current = index_into(current, resolve_index_key(suffix[(pos + 1)...close]))
            pos = close + 1
          else
            return nil
          end
        end

        current
      end

      private def resolve_simple(name : String) : JSON::Any?
        @vars[name.strip]?
      end

      # Marks *host* as the origin host when *current* IS the hostvars
      # magic container and *key* fetched one of its entries - every
      # later fetch inside that entry (and every internal re-render of a
      # fetched value) then renders in that host's scope. Identity check,
      # not name check: a plain variable the play names "hostvars" is
      # not the magic.
      private def enter_hostvars_origin(current : JSON::Any, key : String) : Nil
        return if @origin
        hostvars_raw = @vars["hostvars"]?.try(&.raw)
        return unless hostvars_raw.is_a?(Hash)
        current_hash = current.raw
        return unless current_hash.is_a?(Hash) && current_hash.same?(hostvars_raw)
        @origin = key
      end

      # Ansible's recursive re-templating, applied to a dotted-access
      # BASE variable before walking `.method()`/`.attr` off of it - one
      # more independent copy of the same bug class this engine has fixed
      # repeatedly elsewhere (ExpressionEvaluator's bare-lookup fallback,
      # ConditionalEvaluator's bare when:, FilterEngine's default()
      # argument, ComparisonEvaluator's bare operand): a role var computed
      # from another var/dict lookup (`bootstrap_facts_packages: "{{
      # _bootstrap_packages[...] | default(...) }}"`, robertdebock.
      # bootstrap's own vars/main.yml) is stored in @vars still as its OWN
      # unrendered `{{ }}` text rather than eagerly resolved at role-load
      # time. `resolve_nested` previously fetched that raw templated
      # string as-is and called `.split()` directly on the LITERAL text
      # "{{ _bootstrap_packages[...] }}" instead of its real rendered
      # value (round 18) - only the bare-lookup and filter-chain-head call
      # sites had this guard before, not the dotted-access base fetch.
      private def templated_value?(raw : String) : Bool
        raw.includes?("{{") || raw.includes?("{%") || raw.includes?("{#")
      end

      private def parse_rendered_or_wrap(rendered : String) : JSON::Any
        Krikri.parse_json_or_python_literal(rendered)
      end

      private def rerender_if_templated(value : JSON::Any) : JSON::Any
        return value unless (raw = value.raw).is_a?(String) && templated_value?(raw)
        return value if UnsafeValues.unsafe_text?(raw)

        # Inside a hostvars entry (see @origin) the value belongs to the
        # OTHER host and re-renders in its scope, not the reading host's.
        render_vars = if origin = @origin
                        HostvarsContext.merged_vars(origin, @vars) || @vars
                      else
                        @vars
                      end

        # Depth guard shared with Rerender.if_templated - a cycle can
        # re-enter through either entry point (this method and the
        # Rerender module's), so the counter has to be the same one.
        # Without it a mutually-templated var pair (`a: "{{ b }}"` /
        # `b: "{{ a }}"`) blew the C stack and crashed the whole process;
        # ansible-core fails the task with "Recursive loop detected
        # in template" instead.
        Rerender.with_depth_guard do
          rerender_if_templated_inner(raw, render_vars)
        end
      end

      # The mixed/block-tag re-render path: block tags/comments, or a
      # `{{ }}`-bearing value that is NOT one whole-string span (literal
      # text around the span, or more than one span) needs the FULL
      # template renderer, which understands arbitrary mixed literal-
      # text-plus-`{{ }}` content the way a real `.j2` file does.
      # Inside a strict templating operation (see
      # VarSubstitutor.strict_span_active?) the re-render of a templated
      # variable value is itself a strict templating operation in real
      # ansible-core - a `vars:`/defaults value of `{{ d.missing }}` is
      # rendered lazily AT ITS USE SITE, and the use site's strictness
      # must reach this inner render (the vars cell of the strict-
      # undefined matrix, live-verified vs 2.19.11). substitute(strict:
      # true) is the full strict pipeline: span probes plus block-tag
      # handling.
      private def rerender_full_template(render_vars : Hash(String, JSON::Any), raw : String) : JSON::Any
        strict_span_substitute(render_vars, raw) ||
          parse_rendered_or_wrap(JinjaRenderer.new(render_vars).render(raw))
      end

      # The strict-span half of the re-render paths: when the OUTER
      # templating operation is strict, re-render *raw* through the full
      # strict pipeline (span probes + block-tag handling) so a consumed
      # missing attribute inside the value raises at the use site. nil
      # when no strict span is active - the caller keeps its lenient path.
      private def strict_span_substitute(render_vars : Hash(String, JSON::Any), raw : String) : JSON::Any?
        return nil unless VarSubstitutor.strict_span_active?
        parse_rendered_or_wrap(VarSubstitutor.new(vars: render_vars).substitute(raw, strict: true))
      end

      private def rerender_if_templated_inner(raw : String, render_vars : Hash(String, JSON::Any)) : JSON::Any
        # A raw value containing `{%`/`{#` (block tags/comments, not just
        # a plain `{{ }}` expression) needs the FULL Crinja renderer -
        # ExpressionEvaluator has no concept of block tags at all. Real
        # bug found benchmarking prometheus.prometheus._common's own
        # vars/main.yml: `_common_dependencies: "{% if (...) %}{{ (...)
        # -}}{% else %}{% endif %}"` (a role default, Ansible-
        # written Jinja - block tags ARE valid anywhere a template
        # string is processed, not just in .j2 template FILES) - handing
        # this whole raw text to ExpressionEvaluator (which only knows
        # `{{ }}` spans) returned it completely unrendered, and that
        # literal block-tag text became a package name passed straight
        # to apt-get, a bash syntax error. The OUTER VarSubstitutor#
        # substitute already had this same "{{" vs "{%"/"{#"" branch for
        # its own top-level re-templating pass; this INNER helper (the
        # one plain variable/dotted lookups actually go through) never
        # got the same fix.
        inner = raw.strip
        # Also require exactly one "{{"/"}}" pair total - a string
        # starting with "{{" and ending with "}}" can still hold TWO (or
        # more) separate spans with literal text between them
        # (`"{{ enroot_version }}-{{ enroot_release }}"`, ome.ice's own
        # enroot_version_string default) - the prefix/suffix check alone
        # can't tell that apart from one genuine whole-string span, and
        # slicing off just the first/last 2 characters on a multi-span
        # string leaves the inner "-{{"/"}}-" text in place, producing a
        # malformed expression ExpressionEvaluator can't parse.
        whole_span = inner.starts_with?("{{") && inner.ends_with?("}}") &&
                     (raw.split("{{").size - 1) == 1 && (raw.split("}}").size - 1) == 1

        # Block tags/comments, or a `{{ }}` span that does NOT span the
        # ENTIRE raw value (`"{{ nginx_conf_path }}/nginx.conf"` - a
        # literal suffix after the closing `}}`, or a literal prefix
        # before the opening `{{`, or more than one span) need the full
        # template renderer, which understands arbitrary mixed
        # literal-text-plus-`{{ }}` content the way a real `.j2` file or
        # a Ansible template string does. The single-span,
        # whole-string case below is a narrower, faster path for the
        # overwhelmingly common shape (`vars: x: "{{ y }}"` with nothing
        # else in the string) and is kept as-is for it.
        #
        # Found via Oefenweb.nginx's own vars/main.yml: `nginx_conf_file:
        # "{{ nginx_conf_path }}/nginx.conf"` - the trailing "/nginx.conf"
        # after the span meant `inner.ends_with?("}}")` was false, so the
        # OLD code below left `inner` as the full mixed string and handed
        # it whole to ExpressionEvaluator#evaluate - which expects a bare
        # Jinja EXPRESSION (the content of a SINGLE `{{ }}`), not text
        # that still has literal `{`/`}` characters in it - collapsing a
        # real "/etc/nginx/nginx.conf" (and everything derived from it,
        # here `.lstrip('/')` chained onto it) to an empty string.
        # The caller only gets here for values that DO carry Jinja markers
        # (templated_value? gated), so a non-whole-span value is always
        # the mixed/block-tag shape the full renderer owns.
        unless whole_span
          return rerender_full_template(render_vars, raw)
        end

        inner = inner[2..-3].strip if whole_span
        # Whole-single-span values keep the expression's NATIVE type
        # (ansible-core 2.19 native typing - see
        # Rerender.whole_span_structured): `{{ 42 }}` is the int 42,
        # `{{ '42' }}` the str "42". The old render-then-
        # parse_json_or_python_literal detour re-typed by TEXT shape
        # instead, which got `{{ 42 }}` right by accident (JSON.parse)
        # but turned `{{ '42' }}` into the int 42 too. nil (undefined,
        # engine failure, or not actually whole-span) falls back to the
        # pre-existing render path below, unchanged.
        structured = Rerender.whole_span_structured(render_vars, raw) if whole_span
        return structured if structured
        # Same strict-span propagation as the mixed path above: when the
        # OUTER templating operation is strict, re-render the whole-span
        # value through the strict pipeline so a consumed missing
        # attribute inside the value raises at the use site.
        strict_span_substitute(render_vars, raw).try { |value| return value }
        rendered = ExpressionEvaluator.new(render_vars).evaluate(inner)
        parse_rendered_or_wrap(rendered)
      end

      private def resolve_nested_base(part : String) : JSON::Any?
        if literal = quoted_literal(part)
          JSON::Any.new(literal)
        elsif hash_literal_expr?(part)
          # A literal Jinja dict as the dotted-path base
          # (`{'x86_64': 'amd64', ...}.get(key, default)`) -
          # same reasoning as the quoted-literal case just
          # above: the base is a LITERAL, not a variable name,
          # so the plain @vars lookup below always missed.
          # ExpressionEvaluator already has a full dict-literal
          # parser (used for a bare `{{ {...} }}` span); reused
          # here rather than duplicating it. Found via
          # prometheus.prometheus.node_exporter's own
          # `_node_exporter_go_ansible_arch` (an architecture-
          # name lookup table for its GitHub release download
          # URL) - resolved to nil/"undefined" before, silently
          # corrupting the download URL into a 404.
          rendered = ExpressionEvaluator.new(@vars).evaluate(part)
          parse_rendered_or_wrap(rendered)
        else
          @vars[part]?
        end
      end

      private def resolve_nested(expr : String) : JSON::Any?
        parts = split_dotted_parts(expr)
        # Python's `str.join(iterable)` method-call syntax (`' '.join(my_
        # list)`) - the receiver is a QUOTED STRING LITERAL, not a
        # variable name, unlike every other dotted-path base this method
        # otherwise handles. split_dotted_parts already splits it
        # correctly (parts[0] == "' '", parts[1] == "join(my_list)") -
        # only the base-value resolution below was missing a literal
        # case, so parts[0] always failed the @vars lookup and the whole
        # expression resolved to nil/"undefined". Found via Oefenweb.
        # fail2ban's own `' '.join(fail2ban_dependencies).split()`
        # (building the apt package list) - the whole expression
        # collapsed to the literal text "undefined", used directly as
        # apt's own `name:` param.
        current = resolve_nested_base(parts[0])
        return nil unless current
        current = rerender_if_templated(current) unless unsafe_root?(expr)

        apply_dotted_parts(current, parts[1..-1])
      end

      # The dotted-suffix walking loop `resolve_nested` runs after
      # resolving its own base variable - split out so a caller that
      # already has a resolved value in hand (not a variable NAME) can
      # apply a dotted/method-call suffix to it directly. See
      # #apply_method_suffix for that public entry point - added for
      # ExpressionEvaluator's `lookup(...).method()` shape, where the
      # "base" is a lookup() call's return value, not a `@vars` name.
      # Jinja2 3.x groupby yields _GroupTuple namedtuples (a pair
      # with fields grouper/list that ALSO tuple-indexes and
      # JSON-serializes as an array) - the groupby filter emits a plain
      # 2-element array, so these two field names resolve to the pair's
      # elements the way the namedtuple would. A plain list has no such
      # attribute in Jinja either (renders undefined), but no real
      # template reads .grouper off a non-groupby list.
      private def groupby_pair_attr(raw : Array(JSON::Any), part : String) : JSON::Any?
        return nil unless raw.size == 2 && (part == "grouper" || part == "list")
        raw[part == "grouper" ? 0 : 1]
      end

      private def apply_dotted_parts(current : JSON::Any, parts : Array(String)) : JSON::Any?
        parts.each do |part|
          current = apply_one_dotted_part(current, part)
          return nil unless current
        end

        current
      end

      # The Array branch of #apply_one_dotted_part: numeric dot-indexing
      # into a list (`item.1` meaning `item[1]`) - Jinja2 attribute access
      # falls back to item access, which for a list means an integer
      # index. `with_indexed_items`/`with_together`/`zip()` all yield
      # each item as a plain `[index_or_a, b]` pair, and the idiomatic
      # way to pull the second element back out in a `when:`/`{{ }}` is
      # exactly this dotted form (buluma.dotfiles' own "Remove existing
      # dotfiles file" task gates on `when: "'@' not in item.1.stdout"`
      # over `with_indexed_items: existing_dotfile_info.results`) -
      # previously only Hash key lookup was implemented here, so any
      # numeric part against an Array fell through to the generic `else
      # return nil`, and the `when:` itself then raised "item.1.stdout is
      # undefined" instead of resolving the pair's second element.
      private def apply_list_dotted_part(raw : Array(JSON::Any), part : String) : JSON::Any?
        if (pair = groupby_pair_attr(raw, part))
          return pair
        end
        index = part.to_i?
        # A non-numeric dot part against a list is Python's "object of
        # type 'list' has no attribute 'x'" miss - signal it for the
        # strict probe. A NUMERIC index is owned by the bracket-index
        # wording machinery and stays unsignaled.
        KrikriJinja.note_miss unless index
        return nil unless index
        index += raw.size if index < 0
        return nil unless index >= 0 && index < raw.size
        raw[index]
      end

      # One dotted step of #apply_dotted_parts: the next value, or nil on
      # a miss (split out to keep both methods under ameba's cyclomatic-
      # complexity ceiling).
      private def apply_one_dotted_part(current : JSON::Any, part : String) : JSON::Any?
        dict_method = hash_method_call(current, part)
        return dict_method if dict_method

        string_method = string_method_call(current, part)
        return string_method if string_method

        case raw = current.raw
        when Hash
          fetched = current[part]?
          # A missing key on a RESOLVED dict is a strict-undefined miss
          # signal (see Krikri.strict_undefined_probe_message) - the
          # probe, not this lookup, decides whether the miss was
          # consumed or tolerated.
          KrikriJinja.note_miss unless fetched
          return nil unless fetched
          enter_hostvars_origin(current, part)
          fetched
        when Array
          apply_list_dotted_part(raw, part)
        else
          # `.attr` on a scalar (str/int/bool/None) - Python's "object of
          # type 'str' has no attribute 'x'" - same miss signal.
          KrikriJinja.note_miss
          nil
        end
      end

      # Applies a dotted/method-call SUFFIX (e.g. "splitlines()", the
      # text after a `lookup(...)` call's own closing paren) to an
      # already-resolved value - used by ExpressionEvaluator's
      # `filter_chain_special_head` for `lookup(...).method()` chained
      # directly with no `|` filter in between (round 199, bodsch.tomcat).
      def apply_method_suffix(current : JSON::Any, suffix : String) : JSON::Any?
        return current if suffix.empty?

        saved = @origin
        @origin = nil
        begin
          suffix = suffix[1..] if suffix.starts_with?('.')
          apply_dotted_parts(current, split_dotted_parts(suffix))
        ensure
          @origin = saved
        end
      end

      # Splits a dotted access path on top-level "." only - outside
      # quotes and parens. A naive `expr.split(".")` breaks on a method
      # call whose own argument contains a literal "." (`ansible_facts.
      # distribution_version.split('.')[0]`, geerlingguy.postgresql's own
      # OS-major-version idiom): the argument's dot got treated as a
      # *path* separator too, splitting "split('.')" into two garbled
      # parts ("split('" and "')") instead of leaving it whole for
      # string_method_call below to parse.
      private def split_dotted_parts(expr : String) : Array(String)
        parts = [] of String
        current = String::Builder.new
        depth = 0
        quote_char = nil.as(Char?)

        expr.each_char do |char|
          if quote_char
            current << char
            quote_char = nil if char == quote_char
            next
          end

          case char
          when '\'', '"'
            quote_char = char
            current << char
          when '('
            depth += 1
            current << char
          when ')'
            depth -= 1
            current << char
          when '.'
            if depth == 0
              parts << current.to_s
              current = String::Builder.new
            else
              current << char
            end
          else
            current << char
          end
        end
        parts << current.to_s
        parts
      end

      # Jinja2/Python string method-call syntax (`.split(sep)`) - geerling
      # guy.postgresql/mysql/php's own `ansible_facts.distribution_version
      # .split('.')[0]` idiom for picking an OS-major-version vars file.
      # Only the single-quoted-separator form is needed (the only one
      # these roles use); returns an array of strings, matching Python's
      # own str.split so a trailing `[0]` (handled by resolve_indexed,
      # the caller one level up) picks the first component.
      private def string_method_core_call(current : JSON::Any, part : String) : JSON::Any?
        if part == "split()"
          # No-argument `.split()` - real Python's own `str.split()` (no
          # separator) splits on any whitespace RUN, not individual
          # characters, and drops leading/trailing whitespace/empty
          # pieces - the same semantics the `| split` FILTER was already
          # fixed for (found via geerlingguy.nfs). This is the METHOD-call
          # syntax instead, a separate code path with its own copy of the
          # same gap: only `split('sep')` (a quoted argument) matched the
          # regex below, so the bare no-arg form fell through entirely,
          # resolving to nil/"undefined". Found via robertdebock.bootstrap's
          # own `bootstrap_facts_packages.split()` (round 18) - the whole
          # `{{ }}` collapsed to the literal text "undefined", used
          # directly as a `loop:` value, so `package:` tried (and failed)
          # to install a package literally named "undefined".
          return JSON::Any.new(current.as_s.split.map { |piece| JSON::Any.new(piece) })
        end

        if match = part.match(REGEX_METHOD_SPLIT)
          sep = match[2]
          pieces = sep.empty? ? current.as_s.chars.map(&.to_s) : current.as_s.split(sep)
          return JSON::Any.new(pieces.map { |piece| JSON::Any.new(piece) })
        end

        if match = part.match(REGEX_METHOD_FIND)
          index = current.as_s.index(match[2])
          return JSON::Any.new((index ? index : -1).to_i64)
        end

        if match = part.match(REGEX_METHOD_LSTRIP)
          # Python's str.lstrip(chars) strips any LEADING character that
          # is a MEMBER of chars (a character set, not a prefix-string
          # match) - repeated until a non-member is hit; no argument
          # strips whitespace, matching Python's default. Ansible's
          # Jinja2 environment calls this straight through as a native
          # Python string method (not a `| filter`), so any string
          # variable can use it directly in a plain `{{ }}` expression.
          # Found benchmarking buluma.ssh_keys's own known-hosts.yml:
          # `src: "{{ ssh_keys_known_hosts_path.lstrip('/') }}.j2"` -
          # unimplemented here, the whole `{{ }}` collapsed to the
          # literal text "undefined", and `template:`'s `src:` became
          # the nonexistent path "undefined.j2".
          chars = match[2]?
          return JSON::Any.new(strip_chars(current.as_s, chars, left: true, right: false))
        end

        if match = part.match(REGEX_METHOD_RSTRIP)
          chars = match[2]?
          return JSON::Any.new(strip_chars(current.as_s, chars, left: false, right: true))
        end

        if match = part.match(REGEX_METHOD_STRIP)
          chars = match[2]?
          return JSON::Any.new(strip_chars(current.as_s, chars, left: true, right: true))
        end

        if result = string_method_case_call(current, part)
          return result
        end

        nil
      end

      # Python's str.lower()/str.upper() method-call syntax - logdna.
      # logdna's own `include_tasks: ./package/install_{{ ansible_os_
      # family.lower()}}.yml` (picking the OS-family install task file).
      # Only the `| lower`/`| upper` FILTER spellings were implemented
      # before; the bare Python method-call form fell through resolve_
      # nested entirely, collapsing the whole `{{ }}` to the literal text
      # "undefined" and the include to the nonexistent path
      # "install_undefined.yml".
      private def string_method_case_call(current : JSON::Any, part : String) : JSON::Any?
        return JSON::Any.new(current.as_s.downcase) if part =~ /^lower\(\s*\)$/ && current.raw.is_a?(String)
        return JSON::Any.new(current.as_s.upcase) if part =~ /^upper\(\s*\)$/ && current.raw.is_a?(String)
        nil
      end

      # Jinja2/Python string method-call syntax (`.split(sep)`) - geerling
      # guy.postgresql/mysql/php's own `ansible_facts.distribution_version
      # .split('.')[0]` idiom for picking an OS-major-version vars file.
      # Only the single-quoted-separator form is needed (the only one
      # these roles use); returns an array of strings, matching Python's
      # own str.split so a trailing `[0]` (handled by resolve_indexed,
      # the caller one level up) picks the first component.
      private def string_method_call(current : JSON::Any, part : String) : JSON::Any?
        return nil unless current.raw.is_a?(String)

        if result = string_method_core_call(current, part)
          return result
        end

        if part == "splitlines()"
          # Real bug found live-verifying prometheus.prometheus.
          # node_exporter (round 22): its own _common role's checksum-
          # file parsing (`raw.splitlines() | map(...) | ...`) is a
          # PLAIN `{{ }}` expression (a set_fact value), not inside a
          # `{% %}` block - only escalation to the full Crinja renderer
          # (see python_string_methods.cr) ever reached `.splitlines()`
          # before, so this bare-`{{ }}` code path (the one a set_fact's
          # own value actually goes through) resolved the whole
          # expression to "undefined" instead of raising or falling
          # back - the checksum dict ended up empty, and every download
          # failed its checksum verification. Same Python semantics as
          # TaskExecutor#ansible_splitlines (empty input -> `[]`, one
          # trailing newline doesn't produce a spurious final empty
          # element) - not Crystal's plain `String#split("\n")`.
          text = current.as_s
          lines = text.empty? ? [] of String : text.split("\n")
          lines.pop if lines.last?.try(&.empty?)
          return JSON::Any.new(lines.map { |line| JSON::Any.new(line) })
        end

        if match = part.match(/^startswith\(\s*(['"])(.*)\1\s*\)$/)
          return JSON::Any.new(current.as_s.starts_with?(match[2]))
        end

        if match = part.match(/^endswith\(\s*(['"])(.*)\1\s*\)$/)
          return JSON::Any.new(current.as_s.ends_with?(match[2]))
        end

        if match = part.match(/^join\(\s*(.+?)\s*\)$/)
          # `SEP.join(iterable)` - `current` is the separator (already
          # resolved above, since this is a method call ON the literal
          # base); the argument is a variable reference to the list
          # being joined, the reverse of the Jinja `list | join(sep)`
          # filter's own argument order.
          arg = match[1]
          items = if literal = quoted_literal(arg)
                    [JSON::Any.new(literal)]
                  else
                    @vars[arg]?.try(&.as_a?)
                  end
          return nil unless items
          # Each list element is re-rendered before joining -
          # Ansible's recursive re-templating applies per-element too, not
          # just to the list variable itself. Oefenweb.fail2ban's own
          # fail2ban_dependencies has a templated 2nd element (a ternary
          # choosing a package name or ''), stored raw/unrendered in
          # @vars the same way every other lazily-evaluated default is.
          rendered = render_join_items(items, arg)
          # Coerce non-string elements via format_value instead of a bare
          # .as_s (which raised TypeCastError for ints/dicts) - real
          # Jinja2's join str()s each element.
          return JSON::Any.new(rendered.map { |item| item.as_s? ? item.as_s : format_value(item) }.join(current.as_s))
        end

        nil
      end

      # The join()'s per-element re-render, split out of string_method_
      # call to keep that method's cyclomatic complexity in check - and
      # to carry the unsafe gate (see unsafe_root?): elements resolved
      # through an execution-resolved root are verbatim content, never
      # re-rendered.
      private def render_join_items(items : Array(JSON::Any), source_expr : String) : Array(JSON::Any)
        items.map { |item| unsafe_root?(source_expr) ? item : rerender_if_templated(item) }
      end

      # Python's str.lstrip/rstrip/strip(chars) semantics: chars (nil ==
      # whitespace) is a CHARACTER SET, not a prefix/suffix string - each
      # leading/trailing character that's a member of the set is removed,
      # repeated until a non-member character is hit (or the string is
      # exhausted). Crystal's own String#lstrip/rstrip/strip(String) take
      # a single string arg as a char set already, matching this exactly.
      private def strip_chars(text : String, chars : String?, left : Bool, right : Bool) : String
        result = text
        result = chars ? result.lstrip(chars) : result.lstrip if left
        result = chars ? result.rstrip(chars) : result.rstrip if right
        result
      end

      # A whole-string quoted literal (`'sep'`, `"sep"`) - nil for
      # anything else, including a bare variable name or a literal with
      # extra text around it.
      private def quoted_literal(expr : String) : String?
        stripped = expr.strip
        return nil if stripped.size < 2
        return nil unless (stripped[0] == '\'' && stripped[-1] == '\'') || (stripped[0] == '"' && stripped[-1] == '"')
        stripped[1..-2]
      end

      # A whole-string literal Jinja dict (`{'a': 1}`) - depth-aware only
      # to the extent of checking the outer braces; the actual parsing is
      # delegated to ExpressionEvaluator's own dict-literal support.
      private def hash_literal_expr?(expr : String) : Bool
        stripped = expr.strip
        stripped.starts_with?('{') && stripped.ends_with?('}')
      end

      # Jinja2/Python dict method-call syntax (`.keys()`, `.values()`,
      # `.items()`) on a Hash - dev-sec os_hardening's own
      # `ansible_facts.getent_passwd.keys() | list` (building the
      # system/regular/root account lists every user-management task in
      # that role loops over) is written exactly this way. Previously
      # unrecognized as anything other than a literal (nonexistent) hash
      # key "keys()", silently resolving to undefined and turning that
      # loop into a single bogus iteration.
      private def hash_method_call(current : JSON::Any, part : String) : JSON::Any?
        return nil unless current.raw.is_a?(Hash)
        hash = current.as_h

        case part
        when "keys()"
          JSON::Any.new(hash.keys.map { |key| JSON::Any.new(key) })
        when "values()"
          JSON::Any.new(hash.values)
        when "items()"
          JSON::Any.new(hash.map { |key, value| JSON::Any.new([JSON::Any.new(key), value]) })
        else
          if match = part.match(/^get\(\s*(.+)\s*\)$/)
            dict_get(hash, match[1])
          end
        end
      end

      # Python's `dict.get(key, default=None)` method-call syntax -
      # dev-sec/prometheus-community-style role vars commonly build a
      # lookup table this way: `{'x86_64': 'amd64', ...}.get(ansible_
      # facts['architecture'], ansible_facts['architecture'])` (falling
      # back to the raw architecture name when it's not in the map).
      # Entirely unimplemented before - fell through to the generic
      # dotted-access fallthrough below, which only understands a plain
      # `dict[key]` literal hash lookup, not a method call - resolved to
      # nil/"undefined" regardless of whether the key was actually
      # present. Found via prometheus.prometheus.node_exporter's own
      # `_node_exporter_go_ansible_arch` (architecture-name mapping for
      # its GitHub release download URL) - the corrupted "undefined" arch
      # segment made the whole binary download URL 404.
      private def dict_get(hash : Hash(String, JSON::Any), args : String) : JSON::Any?
        parts = split_top_level_comma(args)
        return nil if parts.empty?

        key = resolve_get_arg(parts[0])
        return nil unless key

        key_str = key.as_s? || key.raw.to_s
        hash[key_str]? || (parts[1]? ? resolve_get_arg(parts[1]) : nil)
      end

      private def split_top_level_comma(args : String) : Array(String)
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
          elsif "[({".includes?(char)
            depth += 1
            current << char
          elsif "])}".includes?(char)
            depth -= 1
            current << char
          elsif char == ',' && depth == 0
            parts << current.to_s.strip
            current = String::Builder.new
          else
            current << char
          end
        end
        parts << current.to_s.strip
        parts.reject(&.empty?)
      end

      private def resolve_get_arg(expr : String) : JSON::Any?
        stripped = expr.strip
        if (stripped.starts_with?('\'') && stripped.ends_with?('\'')) ||
           (stripped.starts_with?('"') && stripped.ends_with?('"'))
          return JSON::Any.new(stripped[1..-2])
        end

        resolve(stripped)
      end

      # Handles a base expression (a bare name or a dotted path) followed
      # by one or more `[...]` index accessors AND/OR further `.attr`
      # access after them, chained left to right - `mylist[0]`,
      # `mydict['key']`, `ansible_facts.getent_passwd[item][4]` (a
      # dotted base, indexed by a *variable's* value, itself further
      # indexed into the resulting list - dev-sec os_hardening's own
      # user-account tasks pull a getent_passwd entry's home-dir field
      # this way), and also a registered LOOPED task's own aggregated
      # results indexed then walked further - `aide_conf.results[0].
      # stat.exists` (openstack.ansible-hardening's own AIDE-config
      # guard). That last shape used to silently drop everything after
      # the final `]` - the old bracket-only regex scan below had no
      # notion of a trailing `.attr` suffix at all, so `results[0].stat.
      # exists` resolved to the *whole* results[0] hash instead of its
      # nested boolean. Piped through `| bool` in a `when:`, any non-
      # empty rendered hash is truthy, so a should-have-been-skipped
      # task ran for real. Delegates to `walk` (already handles both
      # `.attr` and `[idx]` generically, used elsewhere for a computed
      # base value) for everything after the base instead of duplicating
      # that logic with a bracket-only regex.
      private def resolve_indexed(expr : String) : JSON::Any?
        base_end = expr.index('[')
        return nil unless base_end

        base_expr = expr[0...base_end].strip
        return nil if base_expr.empty?

        current = base_expr.includes?('.') ? resolve_nested(base_expr) : resolve_simple(base_expr)
        return nil unless current

        # Same recursive re-templating guard resolve_nested's own base
        # fetch already applies (see that method's own comment for the
        # full story) - a bracket-indexed base can equally be a role var
        # whose OWN value is itself unrendered `{{ }}` text
        # (`docker_repo: "{{ docker_repo_ce_stable }}"`, atosatto.
        # docker-swarm's own vars/main.yml). Without this, `walk`
        # received the literal text "{{ docker_repo_ce_stable }}" as
        # *current* and tried to index a STRING with `['apt_gpg_key']`,
        # always nil/"undefined" instead of the real nested value.
        current = rerender_if_templated(current) unless unsafe_root?(expr)

        walk(current, expr[base_end..])
      end

      # A `[...]` index's inner text: a quoted string literal, an integer
      # literal, a bare identifier (resolved as a variable reference,
      # `list[item]`), or a full sub-expression with its own filter chain
      # (`rsyslog_weight_map[inner_item.type | d('rules')]` - linux-
      # system-roles/logging's rsyslog subrole, computing a config
      # filename's numeric weight prefix by dict-indexing on a defaulted
      # type). That last case used to fall through resolve_simple/
      # resolve_nested (neither of which understands `|`), silently
      # returning the whole unindexed base value instead - delegates to a
      # fresh ExpressionEvaluator the same way ComparisonEvaluator's own
      # evaluate_simple_value already does for a comparison operand.
      # Routes an INDEX KEY that is itself bracket-indexed
      # (`ansible_facts['service_mgr']` as the key in
      # `k3s_service_handler[ansible_facts['service_mgr']]`) through the
      # full `resolve` entry point, which already dispatches indexed/
      # nested/simple correctly based on what *index_expr* contains -
      # `resolve_simple`/`resolve_nested` have no notion of `[...]` at all.
      private def resolve_bracket_index_key(index_expr : String) : String | Int32 | Float64 | Nil
        return nil unless top_level_char_index(index_expr, '[')

        resolved = resolve(index_expr).try { |value| unsafe_root?(index_expr) ? value : rerender_if_templated(value) }
        return nil unless resolved

        case raw = resolved.raw
        when String       then raw
        when Int64, Int32 then raw.to_i
          # A FLOAT index value (a YAML `percona_server_version: 5.7` default
          # subscripting a float-keyed map, Oefenweb.percona_server's
          # `percona_server_libmysqlclient_map[percona_server_version]`) - the
          # JSON engine stores the YAML float key under its string form ("5.7"),
          # so the lookup needs the same numeric-string coercion ints already
          # get. Real Python matches float keys by value (d[5.7] hits key 5.7);
          # krikri cannot represent a non-string YAML key, so the stringified
          # float is the only way to answer the lookup at all.
        when Float64 then raw
        end
      end

      private def resolve_index_key(index_expr : String) : String | Int32 | Float64
        if quoted = quoted_index_literal(index_expr)
          return quoted
        end
        return index_expr.to_i if index_expr.to_i?

        if index_expr.includes?('|')
          rendered = ExpressionEvaluator.new(@vars).evaluate(index_expr)
          return rendered.to_i? || rendered
        end

        # The index itself can be bracket-indexed
        # (`k3s_service_handler[ansible_facts['service_mgr']]`, xanmanning.
        # k3s's own service-manager lookup table) - `resolve_simple`/
        # `resolve_nested` below have no notion of `[...]`, so a nested
        # index expression like this always missed both and fell through
        # to the `else index_expr` branch, using the literal text
        # "ansible_facts['service_mgr']" as the dict key instead of its
        # resolved value ("systemd").
        if bracket_key = resolve_bracket_index_key(index_expr)
          return bracket_key
        end

        # A bare-identifier index key (`dict[some_var]`) needs the same
        # recursive re-templating guard as every other bare-lookup call
        # site in this codebase (see `rerender_if_templated`'s own
        # comment) - `resolve_simple` returns `@vars[name]` completely
        # raw, and a role var computed from another template
        # (prometheus.prometheus._common's own `__common_binary_
        # basename: "{{ _common_binary_url | urlsplit('path') |
        # basename }}"`) had NOT been eagerly resolved at role-load
        # time. Without this, `checksums[__common_binary_basename]`
        # looked up the literal unrendered text "{{ _common_binary_url
        # | ... }}" as the dict key instead of the real filename it
        # renders to - a key that obviously doesn't exist, so the
        # lookup silently returned undefined even though the SAME
        # variable substituted correctly everywhere else (a bare `{{
        # __common_binary_basename }}` task-name/param does go through
        # this guard already). Real bug found live-verifying
        # prometheus.prometheus.node_exporter: every download's
        # checksum verification failed this way.
        resolved = begin
          # The index key is the READING host's data even mid-entry-walk
          # (`hostvars['h2'].list[item]`) - resolve it with the origin
          # cleared so its own value never renders in the other host's
          # scope.
          saved = @origin
          @origin = nil
          (resolve_simple(index_expr) || resolve_nested(index_expr)).try { |value| unsafe_root?(index_expr) ? value : rerender_if_templated(value) }
        ensure
          @origin = saved
        end
        case raw = resolved.try(&.raw)
        when String       then raw
        when Int64, Int32 then raw.to_i
          # A FLOAT index value (a YAML `percona_server_version: 5.7` default
          # subscripting a float-keyed map, Oefenweb.percona_server's
          # `percona_server_libmysqlclient_map[percona_server_version]`) - the
          # JSON engine stores the YAML float key under its string form ("5.7"),
          # so the lookup needs the same numeric-string coercion ints already
          # get. Real Python matches float keys by value (d[5.7] hits key 5.7);
          # krikri cannot represent a non-string YAML key, so the stringified
          # float is the only way to answer the lookup at all.
        when Float64 then raw
        else              index_expr
        end
      end

      private def quoted_index_literal(index_expr : String) : String?
        return nil unless index_expr.size >= 2
        return nil unless index_expr[0] == index_expr[-1] && (index_expr[0] == '\'' || index_expr[0] == '"')
        index_expr[1..-2]
      end

      private def index_into(current : JSON::Any, key : String | Int32 | Float64) : JSON::Any?
        case current.raw
        when Array
          idx = key.is_a?(Int32) ? key : key.to_s.to_i?
          idx ? current[idx]? : nil
        when Hash
          fetched = current[key.to_s]?
          # Missing dict key via bracket subscript - same strict-undefined
          # miss signal as the dotted form (real raises the identical
          # "object of type 'dict' has no attribute ..." message).
          KrikriJinja.note_miss unless fetched
          enter_hostvars_origin(current, key.to_s) if fetched && key.is_a?(String)
          fetched
        when String
          # Jinja2/Python character indexing (`elasticsearch_version[0]`
          # on a plain "7.x" string) - real bug found benchmarking
          # geerlingguy.elasticsearch's own version-branch `when:`
          # (`elasticsearch_version[0] | int < 7` / `>= 7`): this fell
          # through to the `else -> nil` branch below, `| int` on `nil`/
          # "undefined" defaulted to 0, and `0 < 7` picked the WRONG
          # config-file layout (pre-7.x elasticsearch.yml/jvm.options
          # instead of 7+'s elasticsearch.yml/jvm.options.d/heap.options)
          # - Elasticsearch then failed to start outright against the
          # mismatched config. Negative indices supported too, matching
          # Python string indexing (and the Array branch just above).
          idx = key.is_a?(Int32) ? key : key.to_s.to_i?
          return nil unless idx
          char = current.as_s[idx]?
          char ? JSON::Any.new(char.to_s) : nil
        end
      end

      # Renders a variable's value the way Ansible/Jinja2 does when it's
      # interpolated directly into template text - notably, Python's
      # capitalized True/False for booleans, not Crystal's lowercase
      # true/false (verified against ansible-playbook: a `{{ boolvar }}`
      # in a copy/template content string renders "True"/"False"). Public
      # (not just used internally) so FilterEngine's caller can render a
      # filter chain's final JSON::Any result the same way a plain variable
      # lookup would be.
      # The FINAL, user-facing rendering of a `{{ }}` span's value:
      # identical to #format_value except that a container comes out in
      # Python's `repr` form, which is what Ansible produces
      # (`{{ ['a', 'b'] }}` renders `['a', 'b']` there, and rendered
      # `["a","b"]` here). Only the outermost substitution may use this -
      # anything internal needs #format_value's JSON, per its comment.
      def format_value_output(value : JSON::Any) : String
        case value.raw
        when Array, Hash
          python_repr(value)
        else
          format_value(value)
        end
      end

      # Python's `repr` for a JSON::Any, used to render containers the
      # way Ansible does. Scalars follow Python's own spellings
      # (`True`/`False`/`None`); strings follow its quote choice: single
      # quotes normally, double quotes when the string contains a single
      # quote and no double quote, and single quotes with `\'` escapes
      # when it contains both (verified against Ansible's output
      # for all three shapes).
      def python_repr(value : JSON::Any) : String
        case raw = value.raw
        when String
          python_repr_string(raw)
        when Bool
          raw ? "True" : "False"
        when Nil
          # Only INSIDE a container: a bare `{{ none_var }}` renders as
          # empty text in Ansible, which #format_value handles.
          "None"
        when Array
          "[" + raw.map { |item| python_repr(item) }.join(", ") + "]"
        when Hash
          "{" + raw.map { |key, item| "#{python_repr_string(key)}: #{python_repr(item)}" }.join(", ") + "}"
        else
          format_value(value)
        end
      end

      private def python_repr_string(value : String) : String
        escaped = value.gsub("\\", "\\\\")

        if value.includes?('\'') && !value.includes?('"')
          "\"" + escaped + "\""
        elsif value.includes?('\'')
          "'" + escaped.gsub("'", "\\'") + "'"
        else
          "'" + escaped + "'"
        end
      end

      def format_value(value : JSON::Any) : String
        case value.raw
        when String
          # Jinja2 NEVER strips a rendered value's own whitespace -
          # `{{ some_string }}` renders exactly what the variable holds,
          # leading/trailing spaces included (only `{%- -%}` BLOCK-TAG
          # whitespace control, an orthogonal template-syntax feature,
          # strips anything, and it operates on the template text around
          # a tag, never on a variable's own value). This unconditional
          # strip corrupted any variable whose real value legitimately
          # has meaningful leading/trailing whitespace - found via
          # robertdebock.functions' own `functions_strings` test data
          # (" Extra spaces. ", used as-is with no filter at all) commonly
          # rendering as "Extra spaces." on every `{{ }}` reference.
          value.as_s
        when Int64, Int32
          # `JSON::Any#as_i` always narrows to Int32 regardless of the
          # underlying raw type, raising `OverflowError` for any real
          # Int64 value outside Int32's range (~2.1 billion) - a real
          # crash for byte-scale numbers, not just a wrong result.
          # `ansible_facts['mounts'][n].size_available` (Ansible's
          # own field, gigabyte/terabyte-scale byte counts) hits this on
          # any host with more than ~2GB free - found via robertdebock.
          # diskspace's own `item.size_available | int >= kilobytes_
          # available | int` comparison. `raw.to_s` reads the correctly-
          # typed Int64/Int32 union member directly, no narrowing.
          value.raw.to_s
        when Float64
          value.as_f.to_s
        when Bool
          value.as_bool ? "True" : "False"
        when Array
          # JSON-compact on purpose, and NOT Python-repr: this method is
          # the hinge of an internal "render a sub-expression to a
          # String, `JSON.parse` it back into structured data" round
          # trip used throughout expression_evaluator.cr /
          # filter_engine.cr / comparison_evaluator.cr / this file, and
          # Python-repr text is not valid JSON (see JinjaRenderer#
          # evaluate_value!'s own comment - a naive rewrite here breaks
          # that round trip outright, which is exactly what happened
          # when this was first attempted). User-facing rendering of a
          # container goes through #format_value_output instead.
          value.to_json
        when Hash
          value.to_json
        when Nil
          ""
        else
          value.to_s
        end
      end
    end
  end
end
