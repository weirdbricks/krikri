require "json"

module Krikri
  module VariableSubstitutor
    # The select/reject/selectattr/rejectattr family's implementation helpers
    class FilterEngine
      # select(test, *args) / reject(test, *args) - Jinja2's own
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
          regex = self.class.cached_regex(test == "match" ? "^(?:#{pattern})" : pattern)
          !!(str =~ regex)
        when "in"
          compare_value.try(&.raw.as?(Array)).try(&.includes?(item)) || false
        when "truthy"
          # select()/reject() with no test name given at all defaults to
          # Jinja2's own bare truthiness check on the item itself
          # (`select()` alone = "keep every truthy item") - distinct
          # from selectattr's own default ("defined"), since select
          # operates on the item's actual value, not an attribute
          # presence check.
          truthy?(item)
        else
          selectattr_matches?(JSON::Any.new({"_item" => item} of String => JSON::Any), "_item", test, compare_value)
        end
      end

      private def apply_selectattr(value : JSON::Any, args : String, invert : Bool) : JSON::Any
        parts = split_top_level_args(args)
        attr = parts[0]?.try { |part| resolve_default_expression(part) }.try(&.as_s?)
        return value unless attr

        test = parts[1]?.try { |part| resolve_default_expression(part) }.try(&.as_s?) ||
               (invert ? "truthy" : "defined")
        compare_value = parts[2]?.try { |part| resolve_default_expression(part) }
        filtered = as_array(value).select { |item| selectattr_matches?(item, attr, test, compare_value) != invert }
        JSON::Any.new(filtered)
      end

      # `selectattr`/`rejectattr`'s attr argument accepts a dotted path
      # into a nested dict, Jinja2's own behavior for exactly this
      # idiom (`stat_results.results | selectattr('stat.exists', '==',
      # true)`, picking whichever stat: loop result actually exists).
      # A single `item[attr]?` lookup treats "stat.exists" as one
      # literal top-level key, which never exists - always nil,
      # excluding every item regardless of the real nested value. Found
      # benchmarking githubixx.containerd's own "Set modprobe_location"
      # (`modprobe_locations.results | selectattr('stat.exists', '==',
      # True) | map(attribute='path') | first`): stat.exists was
      # correctly true for 2 of 3 candidates, but selectattr excluded
      # all three, so `first` then raised on the resulting empty list -
      # Jinja2's own genuine error text for that case, but reached
      # here for the wrong reason (a selectattr bug, not a real empty
      # candidate set).
      private def dotted_attr_value(item : JSON::Any, attr : String) : JSON::Any?
        attr.split('.').reduce(item) do |current, key|
          return nil unless current
          current.raw.is_a?(Hash) ? current[key]? : nil
        end
      end

      private def selectattr_matches?(item : JSON::Any, attr : String, test : String, compare_value : JSON::Any?) : Bool
        attr_value = item.raw.is_a?(Hash) ? dotted_attr_value(item, attr) : nil

        # A dict-list entry's own attribute can itself be an unrendered
        # template string - openstack.ansible-hardening's own
        # `stig_packages_rhel7` list gives every entry's `state:` as
        # `"{{ security_package_state }}"` rather than a literal
        # "present"/"absent", relying on Ansible's usual recursive
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
        # With the chain head's lazy-leaf deferral (see
        # #strict_render_deferred_leaves), an attribute can now reach this
        # point still in its raw, unresolved-template form. Tests that need
        # the VALUE (equalto/ne/...) must render it strictly - Ansible
        # renders on access and fails on an undefined-bottoming template,
        # and so did this engine before laziness - while the defined/undef
        # presence tests only ask whether the attribute EXISTS, and real
        # Jinja answers that on the lazily-evaluated value: a template that
        # bottoms out at an undefined name IS undefined there (verified
        # against ansible-core 2.19.11: `selectattr('name', 'defined')` over
        # an entry with `name: "{{ undefined_var }}"` yields an EMPTY
        # result, so the gating task skips), while a resolvable template is
        # its rendered value - defined.
        if (vars = @vars) && (raw_string = attr_value.try(&.raw.as?(String))) &&
           (raw_string.includes?("{{") || raw_string.includes?("{%") || raw_string.includes?("{#")) &&
           !chain_root_unsafe? && !UnsafeValues.unsafe_text?(raw_string)
          if test.in?("defined", "undefined")
            substitutor = VarSubstitutor.new(vars: vars)
            attr_value = nil if substitutor.unresolvable_template?(raw_string)
          else
            attr_value = JSON::Any.new(VarSubstitutor.new(vars: vars).strict_render(raw_string))
          end
        end

        case test
        when "equalto", "eq", "=="
          attr_value == compare_value
        when "ne", "!="
          attr_value != compare_value
        when "undefined"
          attr_value.nil?
        when "truthy"
          # rejectattr with no test name at all defaults to Jinja2
          # 3.x's own truthiness check on the attribute value (not the
          # defined-presence check selectattr's no-test fallback here
          # uses) - `results | rejectattr('stat.exists')` must pick out
          # the looped-stat entries whose `exists` is literally false,
          # which are still perfectly well-defined values.
          truthy?(attr_value || JSON::Any.new(nil))
        when "sameas"
          # Jinja2's `sameas` is Python `is` - object identity, which
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
    end
  end
end
