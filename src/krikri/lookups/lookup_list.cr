require "json"

module Krikri
  module VariableSubstitutor
    # List-producing lookups (list dispatch, together, flatten, varnames) -
    # extracted verbatim from expression_evaluator.cr (lookup-dispatch split).
    class ExpressionEvaluator
      private def evaluate_lookup_list(lookup_type : String?, parts : Array(String), kwargs : Array(String), query_mode : Bool = false) : String?
        case lookup_type
        when "list"
          # lookup('list', a, b, c) - Ansible's own list lookup:
          # returns every term given, as a real list (mainly exists so
          # a caller can always treat the result as a list regardless
          # of how many terms were given).
          lookup_scalar_result(parts[1..].map { |part| evaluate_lookup_term(part.strip) }, kwargs, query_mode)
        when "items"
          # lookup('items', list1, list2, ...) - Ansible's own
          # items lookup: flattens list/tuple terms one level
          # (itertools.chain, not a deep flatten) while every other term
          # (a bare string - its characters are NOT split - a dict, a
          # number, None) is kept as ONE item (live-verified against
          # ansible-core 2.19.11: `query('items', 'ab')` is ['ab'], not
          # ['a', 'b']).
          terms = parts[1..].flat_map do |part|
            value = evaluate_lookup_term(part.strip)
            value.as_a? || [value]
          end
          lookup_scalar_result(terms, kwargs, query_mode)
        when "flattened"
          # lookup('flattened', t1, t2, ...) - Ansible's own flattened
          # lookup: deep-flattens every term (nested lists flattened
          # recursively, non-list scalars kept as whole items - a string is
          # never split) and returns the flat list; via the scalar
          # `lookup()` spelling Ansible comma-joins the results. Was
          # entirely unimplemented here - fell through every case to the
          # "undefined" fallback, feeding the literal string "undefined" to
          # the consumer: HanXHX.debian_bootstrap's
          # `pkg: "{{ lookup('flattened', dbs_packages,
          # dbs_distro_packages) }}"` (round 821001) made the apt plugin
          # fail with "No package matching 'undefined' is available".
          items = lookup_flatten(parts[1..].map { |part| evaluate_lookup_term(part.strip) })
          lookup_scalar_result(items, kwargs, query_mode)
        when "together"
          evaluate_lookup_together(parts, kwargs, query_mode)
        when "nested"
          # lookup('nested', list1, list2, ...) - Ansible's own
          # nested lookup: a nested-loop Cartesian product of the given
          # lists (same shape as the `product` filter, but as lookup
          # terms rather than a piped value) - the classic with_nested:
          # source.
          lists = parts[1..].map { |part| lookup_array(evaluate_lookup_term(part.strip)) }
          result = lists.reduce([[] of JSON::Any]) { |acc, list| acc.flat_map { |row| list.map { |item| row + [item] } } }
          lookup_single_element_result(result.map { |row| JSON::Any.new(row) }, kwargs, query_mode)
        when "lines"
          lookup_lines(parts)
        when "varnames"
          evaluate_lookup_varnames(parts)
        when "fileglob"
          evaluate_lookup_fileglob(parts)
        end
      end

      # lookup('together', list1, list2, ...) - Ansible's own
      # together lookup: zips the given lists together (itertools.
      # izip_longest, padding shorter lists with null), returning a list
      # of lists - the classic with_together: parallel-iteration source.
      # Pulled out of #evaluate_lookup_list's own case dispatch to keep
      # that method's cyclomatic complexity under the repo's threshold -
      # purely a split, no behavior change.
      private def evaluate_lookup_together(parts : Array(String), kwargs : Array(String), query_mode : Bool = false) : String
        lists = parts[1..].map { |part| lookup_array(evaluate_lookup_term(part.strip)) }
        size = lists.max_of?(&.size) || 0
        lookup_single_element_result((0...size).map { |i| lists.map { |list| list[i]? || JSON::Any.new(nil) } }.map { |row| JSON::Any.new(row) }, kwargs, query_mode)
      end

      # Ansible's own flattened lookup runs every term through
      # module_utils' deep `flatten` - nested lists flattened recursively,
      # non-list scalars kept as whole items (a string is never split).
      private def lookup_flatten(values : Array(JSON::Any)) : Array(JSON::Any)
        values.flat_map do |value|
          if (arr = value.as_a?)
            lookup_flatten(arr)
          else
            [value]
          end
        end
      end

      # lookup('varnames', 'regex1', 'regex2', ...) - Ansible's own
      # varnames lookup: returns every variable NAME (not value) whose
      # name matches ANY of the given regex patterns. Pulled out of
      # #evaluate_lookup_list's own case dispatch to keep that method's
      # cyclomatic complexity under the repo's threshold - purely a
      # split, no behavior change.
      private def evaluate_lookup_varnames(parts : Array(String)) : String
        patterns = parts[1..].compact_map { |part| quoted_string_literal(part.strip).try(&.as_s?) }.compact_map { |pth| VariableSubstitutor::FilterEngine.cached_regex(pth) rescue nil }
        @vars.keys.select { |name| patterns.any?(&.matches?(name)) }.to_json
      end

      # The community.general Cartesian lookup: an itertools.product over
      # every argument. Each term goes through listify_lookup_plugin_terms
      # - a LIST iterates as-is, a string or any other non-iterable (int,
      # bool, None) wraps as a single-element list, and a dict iterates its
      # keys - so cartesian('ab', ['x','y']) yields [['ab', 'x'],
      # ['ab', 'y']] rather than iterating the string. Any EMPTY argument
      # makes the whole product empty (itertools.product semantics), and
      # zero arguments is the plugin's own hard error
      # ("with_cartesian requires at least one element in each list"),
      # which Ansible surfaces as a real task failure - the same
      # "The lookup plugin '<name>' failed: ..." message shape the generic
      # lookup routing already expects. Each row is the product tuple put
      # through LookupBase._flatten: nested LIST (and tuple) elements
      # spread one level into the row - cartesian([[1, 2], 3], ['x', 'y'])
      # yields [[1, 2, 'x'], [1, 2, 'y'], [3, 'x'], [3, 'y']] (live-verified
      # against ansible-core 2.19.11 + community.general 12.5.0). Pulled
      # out of #evaluate_lookup_list's own case dispatch to keep that
      # method's cyclomatic complexity under the repo's threshold - it
      # sits in #evaluate_lookup's dispatch chain instead of a case
      # there, and returns nil for any other lookup type.
      private def evaluate_lookup_cartesian(lookup_type : String?, parts : Array(String)) : String?
        return nil unless lookup_type == "cartesian"
        cartesian_lists = parts[1..].map { |part| lookup_cartesian_term(evaluate_lookup_term(part.strip)) }
        if cartesian_lists.empty?
          raise Krikri::PythonLookupRunner::LookupError.new(
            "The lookup plugin 'cartesian' failed: with_cartesian requires at least one element in each list"
          )
        end
        cartesian_rows = cartesian_lists.reduce([[] of JSON::Any]) do |acc, cartesian_list|
          acc.flat_map do |cartesian_row|
            cartesian_list.flat_map do |item|
              nested = item.as_a?
              widened_row = cartesian_row.dup
              nested ? widened_row.concat(nested) : widened_row << item
              [widened_row]
            end
          end
        end
        cartesian_rows.to_json
      end

      # One cartesian lookup argument through
      # listify_lookup_plugin_terms: a list iterates as-is (nested lists
      # left to the row's _flatten), a dict iterates its keys, a string is
      # ITS OWN element (stripped) rather than iterating its characters,
      # and every other scalar wraps as a single-element list.
      private def lookup_cartesian_term(value : JSON::Any) : Array(JSON::Any)
        if (array = value.as_a?)
          array
        elsif (hash = value.as_h?)
          hash.keys.map { |key| JSON::Any.new(key) }
        elsif (string = value.as_s?)
          [JSON::Any.new(string.strip)]
        else
          [value]
        end
      end

      private def lookup_array(value : JSON::Any?) : Array(JSON::Any)
        value.try(&.as_a?) || [] of JSON::Any
      end

      # A scalar `lookup(...)`'s list-producing result: ansible-core's
      # _invoke_lookup joins with ",".join and returns the sequence AS-IS
      # when that raises TypeError, so only an all-string result
      # comma-joins - one non-string element (an Int64, or a
      # BIGINT_SENTINEL_PREFIX-marked string, which IS an integer too wide
      # for Int64 - issue #695) keeps the real list. Joining a marked
      # string used to leak the marker into the rendered text. A query()
      # or wantlist=True caller always keeps the list.
      private def lookup_scalar_result(items : Array(JSON::Any), kwargs : Array(String), query_mode : Bool) : String
        list_form = query_mode ||
                    kwargs.any? { |part| part.strip.downcase.starts_with?("wantlist=true") } ||
                    # An EMPTY result is left as the empty sequence (never
                    # joined to ""): 2.19's munging only kicks in for a
                    # truthy result, so `lookup('items', *[])` renders "[]".
                    items.empty? ||
                    lookup_join_list_form?(items)
        # Assigned on BOTH branches: a nested lookup evaluated on this
        # evaluator must never leave a stale true behind a joined str.
        @lookup_list_form = list_form
        if list_form
          # The embedded bare-call renderer (#evaluate_bare_lookup_call)
          # must know this result kept its list - it renders Python repr
          # for list-kept results (and, since issue #698, for an unwrapped
          # single element), never for a joined str (issue #695).
          lookup_single_element_result(items, kwargs, query_mode)
        else
          items.map { |item| item.as_s }.join(",")
        end
      end

      # A plain lookup() whose list result holds EXACTLY ONE non-string
      # element returns the element itself, not a one-element list:
      # ansible-core's _invoke_lookup does ",".join(result) and, on the
      # TypeError that raises, unwraps a length-1 result (issue #698). A
      # BIGINT_SENTINEL_PREFIX-marked string IS that element's integer
      # too. Empty and multi-element results keep the list, as does any
      # query()/wantlist=True call; all-string results are decided by the
      # caller (they still comma-join).
      private def lookup_single_element_result(items : Array(JSON::Any), kwargs : Array(String), query_mode : Bool) : String
        if !query_mode &&
           !kwargs.any? { |part| part.strip.downcase.starts_with?("wantlist=true") } &&
           items.size == 1 && lookup_join_list_form?(items)
          # The embedded bare-call renderer (#evaluate_bare_lookup_call)
          # must repr the unwrapped element the same way it reprs a kept
          # list (it reads #lookup_list_form, never the text's shape).
          @lookup_list_form = true
          return items[0].to_json
        end
        items.to_json
      end

      # Whether a scalar lookup() result must keep its list form instead
      # of comma-joining: ansible-core's _invoke_lookup joins with
      # ",".join and returns the sequence AS-IS when that raises
      # TypeError, so only an all-plain-string result joins - one
      # non-string element (an Int64, or a BIGINT_SENTINEL_PREFIX-marked
      # string, which IS an integer too wide for Int64 - issue #695)
      # keeps the real list (joining a marked string leaked the marker
      # into the rendered text).
      private def lookup_join_list_form?(items : Array(JSON::Any)) : Bool
        items.any? do |item|
          !(raw = item.raw).is_a?(String) || !Krikri.bigint_digits(raw).nil?
        end
      end
    end
  end
end
