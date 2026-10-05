require "json"

module Krikri
  module VariableSubstitutor
    # Filter-argument parsing and resolution: top-level arg splitting, ternary/
    # literal/dict/array parsing, kwarg extraction, and the expression resolvers
    # that turn argument text into values
    class FilterEngine
      # `default(fallback)` or `default(fallback, boolean)` - Jinja2's
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
      # real usage seen so far needs that). Python's capital-T `True`
      # spelling is accepted too - it was previously silently ignored
      # (treated as false), which Jinja2 would honor.
      private def default_boolean_arg?(args : String) : Bool
        split_top_level_args(args)[1]?.try(&.strip).in?("true", "True")
      end

      private def resolve_default_arg(args : String) : JSON::Any
        first_arg = split_top_level_args(args).first? || ""

        # `default(omit)` - Ansible's magic variable that drops the
        # *parameter itself* from the module call rather than substituting
        # any real value (konstruktoid-hardening's "Allow outgoing
        # specified ports" task uses `proto: "{{ item.proto | default(omit)
        # }}"` to skip proto for loop items that don't specify one). `omit`
        # is a bare, unquoted identifier here - not a variable lookup - so
        # it's special-cased before falling into #resolve_expression, which
        # would otherwise treat it as an ordinary (undefined) variable
        # reference. See Krikri::OMIT_SENTINEL for where this value is
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
          return KrikriJinja.evaluate_expression(first_arg, @vars || Hash(String, JSON::Any).new) ||
            JSON::Any.new(nil)
        end

        resolve_expression(first_arg)
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
        @chain_root = VarSubstitutor.expression_root(expr)

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
          resolved ? rerender_if_templated(resolved, expr) : JSON::Any.new(expr)
        else
          JSON::Any.new(expr)
        end
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
      # ipaddr-family argument helpers: a query/count argument may be a
      # quoted literal or a variable/expression reference; resolve and
      # coerce to the core's own types.
      private def resolved_query_arg(arg : String?) : String
        return "" unless arg
        resolved = resolve_expression(arg.strip)
        case raw = resolved.raw
        when Nil
          ""
        when String
          raw
        else
          as_string(resolved)
        end
      end

      private def resolved_int_arg(arg : String?) : Int64?
        return nil unless arg
        resolved = resolve_expression(arg.strip)
        case raw = resolved.raw
        when Int64   then raw
        when Float64 then raw.to_i64
        when String  then raw.strip.to_i64?
        end
      end

      private def resolve_expression(expr : String) : JSON::Any
        expr = expr.strip
        @chain_root = VarSubstitutor.expression_root(expr)
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
          return KrikriJinja.evaluate_expression(expr, @vars || Hash(String, JSON::Any).new) ||
            JSON::Any.new(nil)
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
        return parse_array_literal(expr) if expr.starts_with?('[') && expr.ends_with?(']')

        if int_val = expr.to_i64?
          return JSON::Any.new(int_val)
        elsif float_val = expr.to_f64?
          return JSON::Any.new(float_val)
        end

        if (vars = @vars) && !expr.empty?
          resolved = VariableLookup.new(vars).resolve(expr)
          resolved ? rerender_if_templated(resolved, expr) : JSON::Any.new(nil)
        else
          JSON::Any.new(nil)
        end
      end

      # Parses a `{...}` dict literal (as seen in `default({})`/`combine({a:
      # 1})` arguments, not a real value already carried as JSON::Any) -
      # unquoted keys and single-quoted string values are both Jinja2
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

      # Parses a `[...]` list literal - the array counterpart of
      # #parse_dict_literal, which #resolve_expression recurses into for
      # element values (so nested dicts/lists/scalars all resolve). A
      # dict literal's VALUE being an array (`combine({'l': [1, 2]})`,
      # `default(['a'])`) previously had no branch here at all - `[...]`
      # fell through to a plain (always-undefined) variable lookup and
      # every such value resolved to JSON null, silently DROPPING the
      # data. Found via the round-306 lazy-dict-templating battery's
      # combine(recursive=True, list_merge=...) shapes.
      private def parse_array_literal(expr : String) : JSON::Any
        inner = expr[1..-2].strip
        return JSON::Any.new([] of JSON::Any) if inner.empty?

        JSON::Any.new(split_top_level_args(inner).map { |element| resolve_expression(element.strip) })
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

      # Splits a filter's argument text the way every delegated Group-A
      # tail filter needs: resolved positional varargs plus `name=`-
      # prefixed kwargs, split on top-level commas (quote/bracket aware
      # via #split_top_level_args). Kwarg values go through the full
      # literal/expression resolver (like #parse_kwarg_expr's), so
      # `start=[]`-style non-string literals survive; a bareword that
      # misses every variable resolves to null, exactly like
      # #resolve_expression's own miss.
      private def split_positional_and_kwargs(filter_args : String, kwarg_names : Array(String) = [] of String, any_kwarg : Bool = false)
        positional = [] of JSON::Any
        kwargs = Hash(String, JSON::Any).new
        split_top_level_args(filter_args).each do |arg|
          part = arg.strip
          value_start : Int32? = nil
          name = if any_kwarg
                   # A keyword argument whose NAME isn't fixed up front -
                   # jinja2's own `|format(version=...)` shape, where the
                   # keywords are the format string's keys. An `==` stays a
                   # positional expression (comparison, never an argument
                   # name), as does anything that isn't an identifier.
                   match = part.match(/^([A-Za-z_]\w*)\s*=(?!=)/)
                   if match
                     value_start = match.end(0)
                     match[1]
                   end
                 else
                   kwarg_names.find { |candidate| part.starts_with?("#{candidate}=") }
                 end
          if name
            kwargs[name] = resolve_default_expression(part[value_start || (name.size + 1)..])
          else
            positional << resolve_expression(part)
          end
        end
        {positional, kwargs}
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

      # Parses `name='value'`/`name="value"` out of a filter's argument
      # list - only what `map(attribute=...)` needs, not general keyword
      # argument parsing.
      # Recursively sorts a JSON object's keys - the JSON counterpart of
      # #sort_yaml_keys-style helpers already used for to_nice_yaml's own
      # Crinja copy, needed here for to_nice_json's sort_keys= default.
      # Mirrors Python's os.path.normpath: collapses `.`/`..`/redundant
      # `/` segments without ever making a relative path absolute.
      # Interpolated regex literals are recompiled on every call (Crystal
      # does not cache them) - this sits on the map/sum/flatten/dict2items
      # hot path, so build the pattern once per name in a cache keyed by
      # the (fixed) set of kwarg names callers use.
      private def parse_kwarg(args : String, name : String) : String?
        pattern = KWARG_PATTERNS[name]?
        unless pattern
          pattern = Regex.new("#{Regex.escape(name)}\\s*=\\s*(['\"])(.*?)\\1")
          KWARG_PATTERNS[name] = pattern
        end
        if match = args.match(pattern)
          match[2]
        end
      end

      private KWARG_PATTERNS = Hash(String, Regex).new

      # A filter option Ansible accepts both positionally and as a
      # named kwarg (regex_findall's multiline/ignorecase): the named
      # form wins when both are present.
      private def truthy_arg?(named : JSON::Any?, positional : String?) : Bool
        return truthy?(named) if named
        positional ? truthy?(resolve_expression(positional)) : false
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
