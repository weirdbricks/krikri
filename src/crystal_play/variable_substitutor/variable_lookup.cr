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
      REGEX_METHOD_SPLIT  = /^split\(\s*(['"])(.*)\1\s*\)$/
      REGEX_METHOD_FIND   = /^find\(\s*(['"])(.*)\1\s*\)$/
      REGEX_METHOD_LSTRIP = /^lstrip\(\s*(?:(['"])(.*)\1\s*)?\)$/
      REGEX_METHOD_RSTRIP = /^rstrip\(\s*(?:(['"])(.*)\1\s*)?\)$/
      REGEX_METHOD_STRIP  = /^strip\(\s*(?:(['"])(.*)\1\s*)?\)$/

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
      private def templated_value?(raw : String) : Bool
        raw.includes?("{{") || raw.includes?("{%") || raw.includes?("{#")
      end

      private def parse_rendered_or_wrap(rendered : String) : JSON::Any
        (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
      end

      private def rerender_if_templated(value : JSON::Any) : JSON::Any
        return value unless (raw = value.raw).is_a?(String) && templated_value?(raw)

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
        inner = raw.strip
        whole_span = inner.starts_with?("{{") && inner.ends_with?("}}")

        # Block tags/comments, or a `{{ }}` span that does NOT span the
        # ENTIRE raw value (`"{{ nginx_conf_path }}/nginx.conf"` - a
        # literal suffix after the closing `}}`, or a literal prefix
        # before the opening `{{`, or more than one span) need the full
        # template renderer, which understands arbitrary mixed
        # literal-text-plus-`{{ }}` content the way a real `.j2` file or
        # a real Ansible template string does. The single-span,
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
        if !whole_span && (raw.includes?("{%") || raw.includes?("{#") || raw.includes?("{{"))
          rendered = CrinjaRenderer.new(@vars).render(raw)
          return parse_rendered_or_wrap(rendered)
        end

        inner = inner[2..-3].strip if whole_span
        rendered = ExpressionEvaluator.new(@vars).evaluate(inner)
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

          case raw = current.raw
          when Hash
            current = current[part]?
            return nil unless current
          when Array
            # Numeric dot-indexing into a list (`item.1` meaning
            # `item[1]`) - real Jinja2 attribute access falls back to
            # item access, which for a list means an integer index.
            # `with_indexed_items`/`with_together`/`zip()` all yield
            # each item as a plain `[index_or_a, b]` pair, and the
            # idiomatic way to pull the second element back out in a
            # `when:`/`{{ }}` is exactly this dotted form (buluma.
            # dotfiles' own "Remove existing dotfiles file" task gates
            # on `when: "'@' not in item.1.stdout"` over `with_indexed_
            # items: existing_dotfile_info.results`) - previously only
            # Hash key lookup was implemented here, so any numeric part
            # against an Array fell through to the generic `else return
            # nil`, and the `when:` itself then raised "item.1.stdout is
            # undefined" instead of resolving the pair's second element.
            index = part.to_i?
            return nil unless index
            index += raw.size if index < 0
            return nil unless index >= 0 && index < raw.size
            current = raw[index]
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
          # strips whitespace, matching Python's default. Real Ansible's
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
        resolved = (resolve_simple(index_expr) || resolve_nested(index_expr)).try { |value| rerender_if_templated(value) }
        case raw = resolved.try(&.raw)
        when String       then raw
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
      # The FINAL, user-facing rendering of a `{{ }}` span's value:
      # identical to #format_value except that a container comes out in
      # Python's `repr` form, which is what real Ansible produces
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
      # way real Ansible does. Scalars follow Python's own spellings
      # (`True`/`False`/`None`); strings follow its quote choice: single
      # quotes normally, double quotes when the string contains a single
      # quote and no double quote, and single quotes with `\'` escapes
      # when it contains both (verified against real Ansible's output
      # for all three shapes).
      def python_repr(value : JSON::Any) : String
        case raw = value.raw
        when String
          python_repr_string(raw)
        when Bool
          raw ? "True" : "False"
        when Nil
          # Only INSIDE a container: a bare `{{ none_var }}` renders as
          # empty text in real Ansible, which #format_value handles.
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
          # Real Jinja2 NEVER strips a rendered value's own whitespace -
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
          # `ansible_facts['mounts'][n].size_available` (real Ansible's
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
          # Python-repr text is not valid JSON (see CrinjaRenderer#
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
