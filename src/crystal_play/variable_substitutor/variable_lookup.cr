require "json"
require "./expression_evaluator"
require "./crinja_renderer"

module CrystalPlay
  module VariableSubstitutor
    # VariableLookup - Handles all forms of variable access
    # - Simple: {{ myvar }}
    # - Nested: {{ user.name.first }}
    # - Indexed: {{ array[0] }}, {{ dict['key'] }}
    class VariableLookup
      @vars : Hash(String, JSON::Any)

      def initialize(@vars : Hash(String, JSON::Any))
      end

      # Simple variable lookup
      def simple(name : String) : String
        resolve_simple(name).try { |v| format_value(v) } || "undefined"
      end

      # Nested variable access
      # Example: user.name, config.database.host
      def nested(expr : String) : String
        resolve_nested(expr).try { |v| format_value(v) } || "undefined"
      end

      # Indexed access (array or hash)
      # Example: mylist[0], mydict['key']
      def indexed(expr : String) : String
        resolve_indexed(expr).try { |v| format_value(v) } || "undefined"
      end

      # Resolves any of the three access forms above to its raw JSON::Any
      # value (nil if undefined) rather than a pre-stringified String - used
      # by FilterEngine so a filter chain (`{{ x | sort | join(',') }}`) can
      # carry real array/hash structure from one filter to the next instead
      # of collapsing to a string after every single filter.
      def resolve(expr : String) : JSON::Any?
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

        expr.each_char.with_index do |c, i|
          if q = quote
            quote = nil if c == q
          elsif c == '\'' || c == '"'
            quote = c
          elsif depth == 0 && c == char
            # Checked BEFORE the generic bracket-depth adjustment below -
            # when *char* is itself one of "([{"/")]}" (searching for a
            # literal '[' or '(', not just using them for nesting), the
            # depth-adjustment branch would otherwise always intercept it
            # first, incrementing depth without ever reporting "found at
            # top level" - a genuine top-level '[' or '(' would never be
            # returned at all.
            return i
          elsif "([{".includes?(c)
            depth += 1
          elsif ")]}".includes?(c)
            depth -= 1
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
            current = hash_method_call(current, part) || (current.raw.is_a?(Hash) ? current[part]? : nil)
          when '['
            close = suffix.index(']', pos)
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

      # Real Ansible's recursive re-templating, applied to a dotted-access
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
      private def rerender_if_templated(value : JSON::Any) : JSON::Any
        return value unless (raw = value.raw).is_a?(String) && (raw.includes?("{{") || raw.includes?("{%") || raw.includes?("{#"))

        # A raw value containing `{%`/`{#` (block tags/comments, not just
        # a plain `{{ }}` expression) needs the FULL Crinja renderer -
        # ExpressionEvaluator has no concept of block tags at all. Real
        # bug found benchmarking prometheus.prometheus._common's own
        # vars/main.yml: `_common_dependencies: "{% if (...) %}{{ (...)
        # -}}{% else %}{% endif %}"` (a role default, real Ansible-
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
        if raw.includes?("{%") || raw.includes?("{#")
          rendered = CrinjaRenderer.new(@vars).render(raw)
          return (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
        end

        inner = raw.strip
        inner = inner[2..-3].strip if inner.starts_with?("{{") && inner.ends_with?("}}")
        rendered = ExpressionEvaluator.new(@vars).evaluate(inner)
        (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
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
        current = if literal = quoted_literal(parts[0])
                    JSON::Any.new(literal)
                  elsif hash_literal_expr?(parts[0])
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
                    rendered = ExpressionEvaluator.new(@vars).evaluate(parts[0])
                    (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
                  else
                    @vars[parts[0]]?
                  end
        return nil unless current
        current = rerender_if_templated(current)

        parts[1..-1].each do |part|
          dict_method = hash_method_call(current, part)
          if dict_method
            current = dict_method
            next
          end

          string_method = string_method_call(current, part)
          if string_method
            current = string_method
            next
          end

          case current.raw
          when Hash
            current = current[part]?
            return nil unless current
          else
            return nil
          end
        end

        current
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
      private def string_method_call(current : JSON::Any, part : String) : JSON::Any?
        return nil unless current.raw.is_a?(String)

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

        if match = part.match(/^split\(\s*(['"])(.*)\1\s*\)$/)
          sep = match[2]
          pieces = sep.empty? ? current.as_s.chars.map(&.to_s) : current.as_s.split(sep)
          return JSON::Any.new(pieces.map { |piece| JSON::Any.new(piece) })
        end

        if match = part.match(/^find\(\s*(['"])(.*)\1\s*\)$/)
          index = current.as_s.index(match[2])
          return JSON::Any.new((index ? index : -1).to_i64)
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
          # Each list element is re-rendered before joining - real
          # Ansible's recursive re-templating applies per-element too, not
          # just to the list variable itself. Oefenweb.fail2ban's own
          # fail2ban_dependencies has a templated 2nd element (a ternary
          # choosing a package name or ''), stored raw/unrendered in
          # @vars the same way every other lazily-evaluated default is.
          rendered = items.map { |item| rerender_if_templated(item) }
          return JSON::Any.new(rendered.map(&.as_s).join(current.as_s))
        end

        nil
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
      private def resolve_index_key(index_expr : String) : String | Int32
        if quoted = quoted_index_literal(index_expr)
          return quoted
        end
        return index_expr.to_i if index_expr.to_i?

        if index_expr.includes?('|')
          rendered = ExpressionEvaluator.new(@vars).evaluate(index_expr)
          return rendered.to_i? || rendered
        end

        resolved = resolve_simple(index_expr) || resolve_nested(index_expr)
        case raw = resolved.try(&.raw)
        when String      then raw
        when Int64, Int32 then raw.to_i
        else                   index_expr
        end
      end

      private def quoted_index_literal(index_expr : String) : String?
        return nil unless index_expr.size >= 2
        return nil unless index_expr[0] == index_expr[-1] && (index_expr[0] == '\'' || index_expr[0] == '"')
        index_expr[1..-2]
      end

      private def index_into(current : JSON::Any, key : String | Int32) : JSON::Any?
        case current.raw
        when Array
          idx = key.is_a?(Int32) ? key : key.to_i?
          idx ? current[idx]? : nil
        when Hash
          current[key.to_s]?
        when String
          # Real Jinja2/Python character indexing (`elasticsearch_version[0]`
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
          idx = key.is_a?(Int32) ? key : key.to_i?
          return nil unless idx
          char = current.as_s[idx]?
          char ? JSON::Any.new(char.to_s) : nil
        else
          nil
        end
      end

      # Renders a variable's value the way Ansible/Jinja2 does when it's
      # interpolated directly into template text - notably, Python's
      # capitalized True/False for booleans, not Crystal's lowercase
      # true/false (verified against real ansible-playbook: a `{{ boolvar }}`
      # in a copy/template content string renders "True"/"False"). Public
      # (not just used internally) so FilterEngine's caller can render a
      # filter chain's final JSON::Any result the same way a plain variable
      # lookup would be.
      def format_value(value : JSON::Any) : String
        case value.raw
        when String
          # Strip whitespace from string values (matches Ansible behavior)
          # This prevents issues with trailing newlines from command output
          value.as_s.strip
        when Int64, Int32
          value.as_i.to_s
        when Float64
          value.as_f.to_s
        when Bool
          value.as_bool ? "True" : "False"
        when Array
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
