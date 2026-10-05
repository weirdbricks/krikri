require "json"

module Krikri
  module VariableSubstitutor
    # Shared value coercion/conversion helpers used by the dispatch and the
    # family helpers (stringification, array/dict coercion, flattening,
    # sorting, numeric coercion, truthiness)
    class FilterEngine
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
          # Real Python/Jinja2's len(None) raises TypeError - found via
          # levonet.ci_github_pr_description's `... | length` on a None
          # input, where krikri's own leniency (returning 0) let a task
          # pass that Ansible fails outright with this exact
          # message.
          raise "object of type 'NoneType' has no len()"
        when Int64, Int32, Float64, Bool
          # Same Python-parity class as the NoneType case above, found
          # via srsp.oracle-java (nested dep of wcm_io_devops.aem_cms):
          # `when: java_version > 8 and java_subversion | length == 0`
          # where java_subversion holds a native YAML float (0.1).
          # ansible-core fails the task outright ("object of type
          # '_AnsibleTaggedFloat' has no len()" on 2.19; plain 'float'
          # on <= 2.18), while the `else` coercion below happily took
          # the decimal string repr's length (3) - and because this
          # lenient answer only surfaced through the FALLBACK path (the
          # Crinja-first evaluation raises, gets rescued, lands here),
          # the task silently skipped/ran instead of failing, leaving
          # krikri to execute ~40 more tasks before dying on a phantom
          # downstream error and diverging the whole recap. len(int/
          # float/bool) has no Python answer but TypeError.
          raise "object of type '#{value.raw.is_a?(Bool) ? "bool" : value.raw.is_a?(Float64) ? "float" : "int"}' has no len()"
        else
          as_string(value).size
        end
      end

      private def as_array(value : JSON::Any) : Array(JSON::Any)
        value.as_a? || [] of JSON::Any
      end

      # Same shape as as_array above - if value is already a JSON Hash,
      # return it; otherwise return an empty Hash.
      #
      # NOTE (round185): this is a coercion for a non-dict value that is
      # nonetheless DEFINED, nothing more. It used to claim it made
      # dict2items "tolerant of undefined ... the way Ansible itself is",
      # which was factually wrong - Ansible hard-fails
      # `{{ x | dict2items }}` for an undefined x, and this leniency was
      # what made a genuinely undefined loop source silently resolve to
      # zero items (buluma.environment). The undefined case is now caught
      # BEFORE any filter runs, by Krikri.undefined_filter_chain_
      # source at the strict-templating and loop-resolution entry points,
      # so nothing downstream of here has to distinguish "missing" from
      # "present but not a dict" - which JSON::Any cannot express anyway.
      private def as_hash(value : JSON::Any) : Hash(String, JSON::Any)
        value.as_h? || {} of String => JSON::Any
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

      private def python_json_dump(value : JSON::Any, io : IO) : Nil
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

      # Jinja2's min/max compare items natively: numbers by value,
      # strings lexicographically. The old min_by/max_by over numeric()
      # coerced every non-numeric item to 0.0, so `['b','a'] | min`
      # returned 'b'. Python 3 would raise TypeError on a mixed
      # number/string comparison; ordering numbers before strings keeps
      # homogeneous-list behavior identical and gives mixed lists a
      # deterministic order instead of a crash.
      private def jinja_extreme(array : Array(JSON::Any), prefer_less : Bool) : JSON::Any?
        return nil if array.empty?
        best = array.first
        array.each do |item|
          cmp = jinja_native_compare(item, best)
          better = prefer_less ? cmp < 0 : cmp > 0
          best = item if better
        end
        best
      end

      private def jinja_native_compare(a : JSON::Any, b : JSON::Any) : Int32
        a_num = a.raw.is_a?(Int64 | Int32 | Float64)
        b_num = b.raw.is_a?(Int64 | Int32 | Float64)
        if a_num && b_num
          # Float#<=> is nilable (NaN); compare by difference instead.
          diff = numeric(a) - numeric(b)
          diff < 0 ? -1 : diff > 0 ? 1 : 0
        elsif a_num
          -1
        elsif b_num
          1
        else
          as_string(a) <=> as_string(b)
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
    end
  end
end
