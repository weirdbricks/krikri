require "crinja"

# Real Jinja2's `first`/`list`/`join` filters are lenient about an
# Undefined target - `{{ some_unset_list | join(',') }}` renders `''`,
# not a crash - a very common shape in real Ansible role templates
# (a role's `defaults/main.yml` sets a list var; some other role or an
# override layer legitimately never sets it; the template still runs the
# filter chain regardless). Vendored Crinja's versions
# (lib/crinja/src/lib/filter/collections.cr, .../join.cr) all raise
# `TypeError` on Undefined input instead, crashing the WHOLE render (not
# just that one line) - found via the differential test harness
# (scripts/crinja_corpus/, see CRINJA.md).
#
# `Crinja.filter(:name) { ... }` appends another entry to
# `Filter::Library.defaults`, an array iterated positionally by
# `register_defaults` (unlike `Operator::Library`, which hardcodes its
# operator list directly in the method body - see
# crinja_in_operator_ext.cr's own comment on that) - a later `<<` for the
# same name overwrites the earlier `Hash`-backed `@store` entry, so
# simply re-registering `:first`/`:list`/`:join` here (this file requires
# after vendored `crinja` is fully loaded) replaces vendor's versions
# outright, no `previous_def`/monkey-patch machinery needed.
module Crinja::Filter
  Crinja.filter(:first) do
    if target.undefined?
      Crinja::UNDEFINED
    else
      target.first.raw
    end
  end

  Crinja.filter(:list) do
    value = target.raw

    case value
    when String
      value.chars
    when Array
      value
    when Undefined
      [] of Value
    when .responds_to?(:to_a)
      target.to_a
    else
      raise TypeError.new("target for list filter cannot be converted to list")
    end
  end

  Crinja.filter({separator: "", attribute: nil}, :join) do
    if target.undefined?
      ""
    else
      separator = arguments["separator"].to_string
      attribute = arguments["attribute"]

      if target.sequence?
        do_attribute = attribute.truthy?
        attr_name = attribute.to_s
        SafeString.build do |io|
          target.join(io, separator) do |item|
            if do_attribute
              item = Resolver.resolve_attribute(attr_name, item)
            end
            io << env.stringify(item)
          end
        end
      else
        raise TypeError.new("#{target} must be a sequence to join it")
      end
    end
  end

  # Real Jinja2's string filters (`trim`, `replace`, ...) coerce their
  # target through Python's `soft_str()` internally, which stringifies a
  # (non-strict) Undefined to `''` rather than raising - so
  # `{{ some_unset_string | trim }}` renders `''` in real Ansible.
  # Vendored Crinja's versions call `target.as_s_or_safe`, which raises
  # `Crinja::UndefinedError` on an Undefined target instead, crashing the
  # whole render. Same overwrite-by-re-registering approach as
  # `first`/`list`/`join` above.
  Crinja.filter(:trim) do
    if target.undefined?
      ""
    else
      target.as_s_or_safe.strip
    end
  end

  Crinja.filter({old: UNDEFINED, new: UNDEFINED, count: nil}, :replace) do
    if target.undefined?
      ""
    else
      search = arguments["old"].to_s
      replace = arguments["new"]
      count = arguments["count"]

      if count.raw.nil?
        target.as_s_or_safe.gsub(search, replace)
      else
        string = target.to_s
        count.to_i.times do
          running = false
          string = string.sub(search) { running = true; replace }
          break unless running
        end
        string
      end
    end
  end

  # `sum(attribute=none, start=0)` - real Python `sum()` supports any
  # `start` value `+` is defined for, not just numbers - Ansible roles
  # lean on this to FLATTEN a list of lists via
  # `| sum(attribute='packages', start=[])` (dev-sec/konstruktoid-
  # hardening's own STIG package-list pattern:
  # `stig_packages_rhel7 | selectattr(...) | sum(attribute='packages',
  # start=[])`, concatenating each matched item's own `packages` list
  # into one flat list). Vendored Crinja's version always does
  # `arguments["start"].as_number`, raising a raw `Cast from
  # Array(Crinja::Value) to (Float64 | Int32 | Int64) failed` the moment
  # `start:` isn't numeric. Re-registered (overwrite-by-later-`<<`, same
  # pattern as `first`/`list`/`join` above) to branch on `start`'s own
  # type: array-typed `start` concatenates, everything else keeps the
  # vendored numeric-sum behavior unchanged.
  Crinja.filter({attribute: nil, start: 0}, :sum) do
    attribute = arguments["attribute"].as_s?
    start = arguments["start"]

    if (start_array = start.raw).is_a?(Array(Value))
      result = start_array.dup
      target.each do |item|
        item = Resolver.resolve_dig(attribute, item) unless attribute.nil?
        raw = item.raw
        if raw.is_a?(Array(Value))
          result.concat(raw)
        else
          result << item
        end
      end
      result
    else
      sum = start.as_number
      target.each do |item|
        item = Resolver.resolve_dig(attribute, item) unless attribute.nil?
        raw = item.raw
        if raw.is_a?(Crinja::Number)
          sum += raw
        else
          raise TypeError.new("cannot add #{raw.class} to sum, value: #{raw.inspect}")
        end
      end
      sum
    end
  end

  # `unique(case_sensitive=false, attribute=none)` - not implemented in
  # Crinja at all ("no filter with name \"unique\" registered", failing
  # any `| ... | unique | ...` filter pipeline outright). A common
  # pipeline tail (`| map(...) | unique | list`) in real role templates.
  # Preserves first-occurrence order, matching real Jinja2.
  Crinja.filter({case_sensitive: false, attribute: nil}, :unique) do
    case_sensitive = arguments["case_sensitive"].truthy?
    attribute = arguments["attribute"]
    has_attribute = !attribute.none?

    seen = Set(String).new
    result = [] of Value

    target.each do |item|
      key_value = has_attribute ? Resolver.resolve_dig(attribute, item) : item
      key = key_value.to_s
      key = key.downcase unless case_sensitive

      unless seen.includes?(key)
        seen << key
        result << item
      end
    end

    result
  end
end
