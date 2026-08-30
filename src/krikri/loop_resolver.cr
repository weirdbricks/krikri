require "json"

module Krikri
  # LoopResolver - Turns Ansible's various with_* loop sources into a flat,
  # order-preserving Array(JSON::Any) of loop items ready to assign to `item`.
  #
  # with_fileglob is deliberately NOT handled here: it needs the runtime
  # variable context (to substitute {{ vars }} in the pattern) and the
  # filesystem, so it is resolved by TaskExecutor at execution time instead
  # of by the parser.
  module LoopResolver
    # with_dict: {a: 1, b: 2} -> [{"key" => "a", "value" => 1}, {"key" => "b", "value" => 2}]
    # Access in a task via item.key / item.value.
    def self.with_dict(hash : Hash(String, JSON::Any)) : Array(JSON::Any)
      hash.map do |key, value|
        JSON::Any.new({"key" => JSON::Any.new(key), "value" => value})
      end
    end

    # with_nested: [[a, b], [x, y]] -> [[a,x], [a,y], [b,x], [b,y]]
    # The first list varies slowest (outermost loop), matching Ansible.
    # Access in a task via item[0], item[1], ...
    def self.with_nested(lists : Array(Array(JSON::Any))) : Array(JSON::Any)
      combos = lists.reduce([[] of JSON::Any]) do |acc, list|
        acc.flat_map { |combo| list.map { |item| combo + [item] } }
      end
      combos.map { |combo| JSON::Any.new(combo) }
    end

    # with_community.general.flattened: flattens a set of per-source lists
    # into one flat list of items, in order - this module's own copy was
    # dead code (never called from anywhere - grep for `LoopResolver.
    # with_flattened` before assuming otherwise), and confusingly *looked*
    # correct despite that. The real, actually-wired-up implementation
    # lives in TaskExecutor#resolve_loop_flattened, which needs the
    # runtime variable context to template each raw source string first
    # (this module's other with_* methods all operate post-templating,
    # already-resolved JSON::Any sources - with_flattened's own sources
    # are usually a mix of literal strings and exactly one `{{ var }}`
    # reference, so templating can't happen at parse time the way the
    # others above do).
    #
    # with_subelements(list, subelement_key) - for each dict in *list*,
    # yield [parent_dict, subelement] pairs for every element of that
    # dict's subelement_key list. Access in a task via item[0] (the parent
    # dict) and item[1] (the subelement). dev-sec os_hardening uses it to
    # iterate the stdout_lines each of several shell/find results.
    def self.with_subelements(list : Array(JSON::Any), subelement : String) : Array(JSON::Any)
      result = [] of JSON::Any
      list.each do |entry|
        unless entry.raw.is_a?(Hash)
          result << entry
          next
        end
        sub_list = entry.as_h[subelement]?.try(&.as_a?) || [] of JSON::Any
        sub_list.each do |sub|
          result << JSON::Any.new([entry, sub])
        end
      end
      result
    end

    # with_indexed_items: [x, y] -> [["0", x], ["1", y]]
    # Access in a task via item[0] (index) and item[1] (value).
    def self.with_indexed_items(items : Array(JSON::Any)) : Array(JSON::Any)
      items.map_with_index do |item, index|
        JSON::Any.new([JSON::Any.new(index.to_s), item])
      end
    end

    # with_sequence: Ansible-style numeric ranges.
    # Accepts either a bare count ("5") or space-separated key=value pairs
    # (start=1 end=10 stride=2 format=host%02d). Defaults: start=1, stride=1
    # (or -1 when the range runs backwards), format="%d".
    def self.with_sequence(spec : String) : Array(JSON::Any)
      start, final_end, stride, format = parse_sequence_spec(spec)
      sequence(start, final_end, stride).map { |num| JSON::Any.new(format % num) }
    end

    # Parse the "start=1 end=10 stride=2 format=host%02d" mini-syntax (or a
    # bare count like "5") into a concrete (start, end, stride, format) tuple.
    private def self.parse_sequence_spec(spec : String) : {Int32, Int32, Int32, String}
      pairs = spec.strip.to_i? ? {"end" => spec.strip} : parse_key_value_pairs(spec)

      start = pairs["start"]?.try(&.to_i) || 1
      stride = pairs["stride"]?.try(&.to_i)
      format = pairs["format"]? || "%d"

      end_value = if count = pairs["count"]?.try(&.to_i)
                    start + (count - 1) * (stride || 1)
                  else
                    pairs["end"]?.try(&.to_i)
                  end

      final_end = end_value || start
      stride ||= final_end >= start ? 1 : -1

      {start, final_end, stride, format}
    end

    # Split "start=1 end=10 stride=2" into {"start" => "1", "end" => "10", "stride" => "2"}.
    private def self.parse_key_value_pairs(spec : String) : Hash(String, String)
      pairs = Hash(String, String).new

      spec.strip.split.each do |pair|
        key, sep, value = pair.partition('=')
        pairs[key] = value unless sep.empty?
      end

      pairs
    end

    # Walk start..end (inclusive) in steps of stride, in either direction.
    private def self.sequence(start : Int32, final_end : Int32, stride : Int32) : Array(Int32)
      values = [] of Int32
      return values if stride == 0

      n = start
      if stride > 0
        while n <= final_end
          values << n
          n += stride
        end
      else
        while n >= final_end
          values << n
          n += stride
        end
      end

      values
    end
  end
end
