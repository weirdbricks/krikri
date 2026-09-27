require "json"
require "base64"

module Krikri
  module VariableSubstitutor
    # Miscellaneous lookups (sequence, random_string, merge_variables,
    # subelements, password, csvfile, ini) - extracted verbatim from
    # expression_evaluator.cr (lookup-dispatch split).
    class ExpressionEvaluator
      private def evaluate_lookup_misc(lookup_type : String?, parts : Array(String), kwargs : Array(String)) : String?
        case lookup_type
        when "sequence"
          # lookup('sequence', 'start=1 end=5 stride=1 format=web%02d')
          # - real Ansible's own sequence lookup: generates a numeric
          # range (the classic with_sequence: source), formatted via
          # format= (Python %-style, Crystal's String#% is the same
          # printf-family syntax) when given.
          raw_arg = parts[1]?.try { |part| evaluate(part.strip) }
          return "undefined" unless raw_arg
          evaluate_sequence_lookup(raw_arg)
        when "indexed_items"
          # lookup('indexed_items', list) - real Ansible's own
          # indexed_items lookup: [index, item] pairs (Python's
          # enumerate()), the classic with_indexed_items: source.
          source = parts[1]?.try { |part| evaluate_lookup_term(part.strip) }
          return "undefined" unless source
          lookup_array(source).map_with_index { |item, i| [JSON::Any.new(i.to_i64), item] }.to_json
        when "random_choice"
          # lookup('random_choice', list1, list2, ...) - real Ansible's
          # own random_choice lookup: every given term concatenated into
          # one list, then a single random element returned.
          # A single SCALAR result (unlike the always-array lookups
          # above) - formatted via @lookup.format_value rather than
          # .to_json, so a bare `{{ lookup('random_choice', l) }}`
          # renders the plain value text ("only"), not a quoted JSON
          # string literal ("\"only\"").
          items = parts[1..].flat_map { |part| lookup_array(evaluate_lookup_term(part.strip)) }
          return "undefined" if items.empty?
          @lookup.format_value(items.sample)
        when "subelements"
          lookup_subelements(parts)
        when "random_string"
          lookup_random_string(parts, kwargs)
        when "merge_variables"
          lookup_merge_variables(parts, kwargs)
        end
      end

      # lookup('community.general.random_string', length=N, base64=bool, ...)
      # - community.general's random_string lookup: generates a random
      # string on the CONTROLLER for secrets/salts, entirely
      # unimplemented before (fell through to the "undefined"
      # fallback, so juju4.pocketid's own `secret: "{{
      # lookup('community.general.random_string', length=secretlength,
      # base64=secretbase64) }}"` wrote the literal sentinel text to
      # disk as the secret). Mirrors the real plugin's full option set
      # and generation pipeline: build the character pool from the
      # upper/lower/numbers/special flags, draw the guaranteed-minimum
      # characters FIRST (min_numeric/min_lower/min_upper/min_special,
      # in that fixed order), fill the rest from the full pool, shuffle
      # (only when unseeded - the real plugin skips the shuffle when
      # seed= is given, leaving min_* characters clustered at the
      # front, a documented quirk this replicates), then optional
      # base64. No positional terms: real Ansible's own
      # check_for_no_terms errors on them, this raises likewise rather
      # than silently ignoring the term.
      private def lookup_random_string(parts : Array(String), kwargs : Array(String)) : String
        unless parts[1..].empty?
          raise "The lookup plugin 'random_string' does not accept search terms, only keyword arguments"
        end
        terms = kwargs.map(&.strip)
        unless terms.all?(&.includes?('='))
          raise "The lookup plugin 'random_string' does not accept search terms, only keyword arguments"
        end
        opts = terms.compact_map do |term|
          key, sep, value = term.partition('=')
          sep.empty? ? nil : {key.strip, evaluate(value)}
        end.to_h

        length = opts["length"]?.try(&.to_i?) || 8
        seed = opts["seed"]?
        rng = seed ? Random.new(seed.hash) : nil
        pick = ->(n : Int32) {
          r = rng
          r ? r.rand(n) : Random::Secure.rand(n)
        }

        char_classes = random_string_char_classes(opts)
        available_chars_set, values = random_string_pool_and_minimums(opts, char_classes, pick)

        values += draw_random_chars(pick, available_chars_set, length - values.size)
        # Only reached when seed is nil (the `unless seed` guard) - rng is
        # always nil there too, so this always shuffles with a fresh RNG.
        values = values.chars.shuffle!(Random.new).join unless seed
        lookup_flag(opts, "base64", false) ? Base64.strict_encode(values) : values
      end

      # The four base character-class pools for #lookup_random_string,
      # with ignore_similar_chars: filtering already applied (matching
      # the real plugin's ordering - this filtering happens BEFORE
      # override_special/override_all are ever considered, so an
      # override bypasses it entirely, same as the real plugin's own
      # `special_chars = override_special` REPLACING the filtered value).
      private def random_string_char_classes(opts : Hash(String, String)) : Tuple(String, String, String, String)
        number_chars = "0123456789"
        lower_chars = "abcdefghijklmnopqrstuvwxyz"
        upper_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        special_chars = "!\\\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
        return {number_chars, lower_chars, upper_chars, special_chars} unless lookup_flag(opts, "ignore_similar_chars", false)

        similar = opts["similar_chars"]? || "il1LoO0"
        {number_chars.delete(similar), lower_chars.delete(similar), upper_chars.delete(similar), special_chars.delete(similar)}
      end

      # override_all: bypasses everything below it (upper:/lower:/
      # numbers:/special:/override_special:/min_*) entirely, matching
      # the real plugin's own `if override_all: ... else: ...` shape -
      # nothing in this branch runs at all when it's set, min_* draws
      # included. Returns {available_chars_set, values-drawn-so-far}.
      private def random_string_pool_and_minimums(opts : Hash(String, String), char_classes : Tuple(String, String, String, String), pick : Proc(Int32, Int32)) : Tuple(String, String)
        if override_all = opts["override_all"]?.presence
          return {override_all, ""}
        end

        number_chars, lower_chars, upper_chars, special_chars = char_classes
        special_chars = opts["override_special"]?.presence || special_chars

        available_chars_set = String.build do |io|
          io << upper_chars if lookup_flag(opts, "upper", true)
          io << lower_chars if lookup_flag(opts, "lower", true)
          io << number_chars if lookup_flag(opts, "numbers", true)
          io << special_chars if lookup_flag(opts, "special", true)
        end

        minimums = {
          {number_chars, "min_numeric"}, {lower_chars, "min_lower"},
          {upper_chars, "min_upper"}, {special_chars, "min_special"},
        }
        values = String.build do |io|
          minimums.each do |(pool, key)|
            io << draw_random_chars(pick, pool, opts[key]?.try(&.to_i?) || 0)
          end
        end

        {available_chars_set, values}
      end

      # One guaranteed-minimum/remainder draw for #lookup_random_string.
      # Mirrors the real plugin's get_random(): an empty pool raises
      # ("Available characters cannot be None, please change
      # constraints") BEFORE the count check, so a negative/zero count
      # still raises when the pool itself is empty (all four class
      # flags false with nothing to draw from), while a zero count
      # against a live pool draws nothing.
      private def draw_random_chars(pick : Proc(Int32, Int32), pool : String, count : Int32) : String
        raise "Available characters cannot be None, please change constraints" if pool.empty?
        return "" if count <= 0
        String.build(count) { |io| count.times { io << pool[pick.call(pool.size)] } }
      end

      # Ansible-style boolean coercion for a random_string keyword's
      # evaluated text (a bare `true` variable renders "True"/"False"
      # via format_value, so both cases must be accepted).
      private def lookup_flag(opts : Hash(String, String), key : String, default : Bool) : Bool
        raw = opts[key]?
        return default unless raw
        raw.downcase.in?("true", "1", "yes", "on")
      end

      # lookup('community.general.merge_variables', pattern, ...,
      # pattern_type='suffix', initial_value=[]) - community.general's
      # merge_variables lookup: collects every variable NAME in scope
      # matching the given pattern(s), sorts them alphabetically (the
      # real plugin's documented order), and merges their values in that
      # order (dicts deep-merge, lists concatenate, anything else the
      # later value replaces). The no-match path is the one real roles
      # hit most: thulium_drake.sshd (round 813042) defines
      # sshd_configs: "{{ lookup('community.general.merge_variables',
      # '_sshd_configs__to_merge', pattern_type='suffix',
      # initial_value=[]) }}" where NO variable ends with the suffix -
      # real Ansible returns initial_value untouched (rendered, not
      # "undefined"), so `when: sshd_configs | length > 0` skips the
      # task cleanly; unimplemented here, the lookup fell through to the
      # "undefined" fallback and resolve_loop_template turned the
      # literal sentinel into a fatal UndefinedVariableError instead.
      # Scoped to what real roles use: no groups:/override:/dict_merge:
      # cross-host options (same scope decision as random_string).
      private def lookup_merge_variables(parts : Array(String), kwargs : Array(String)) : String
        patterns = parts[1..].map { |part| evaluate(part.strip) }
        return "undefined" if patterns.empty?

        opts = kwargs.compact_map do |term|
          key, sep, value = term.partition('=')
          sep.empty? ? nil : {key.strip, value}
        end.to_h
        pattern_type = opts["pattern_type"]?.try { |raw| evaluate(raw.strip) } || "regex"
        # initial_value: may itself be a template (`initial_value=[]`),
        # so render it through the same machinery before parsing.
        initial = opts["initial_value"]?.try { |raw| Krikri.parse_json_or_python_literal(evaluate(raw.strip)) }

        matched = @vars.keys.select { |name| merge_variables_matches?(name, pattern_type, patterns) }.sort!
        return initial ? initial.to_json : "[]" if matched.empty?

        result = initial
        matched.each do |name|
          result = merge_variables_combine(result, @vars[name])
        end
        result ? result.to_json : "[]"
      end

      private def merge_variables_matches?(name : String, pattern_type : String, patterns : Array(String)) : Bool
        patterns.any? do |pattern|
          case pattern_type
          when "prefix" then name.starts_with?(pattern)
          when "suffix" then name.ends_with?(pattern)
          else               name.matches?(Regex.new(pattern))
          end
        end
      end

      # One merge step for #lookup_merge_variables: nil seed adopts the
      # first value outright, dict+dict deep-merges (later wins on
      # scalar collisions), list+list concatenates, anything else the
      # later value replaces - the real plugin's default merge shape.
      private def merge_variables_combine(current : JSON::Any?, value : JSON::Any) : JSON::Any
        return value unless current
        current_h, value_h = current.as_h?, value.as_h?
        if current_h && value_h
          merged = current_h.dup
          value_h.each do |key, sub|
            merged[key] = merged.has_key?(key) ? merge_variables_combine(merged[key], sub) : sub
          end
          return JSON::Any.new(merged)
        end
        current_a, value_a = current.as_a?, value.as_a?
        return JSON::Any.new(current_a + value_a) if current_a && value_a
        value
      end

      private def lookup_subelements(parts : Array(String)) : String
        # lookup('subelements', list_of_dicts, 'subkey', {
        # skip_missing: true}) - real Ansible's own subelements
        # lookup: for each dict, yields [parent_dict, child_item] for
        # every item in parent_dict[subkey] - the classic with_
        # subelements: source (e.g. iterating {user, group} for every
        # group in each user's own `groups:` list).
        source = parts[1]?.try { |part| evaluate_lookup_term(part.strip) }
        subkey = parts[2]?.try { |part| quoted_string_literal(part.strip) }.try(&.as_s?)
        return "undefined" unless source && subkey

        skip_missing = parts[3]?.try { |part| evaluate_lookup_term(part.strip) }.try(&.as_h?).try(&.["skip_missing"]?).try(&.as_bool?) || false
        result = [] of JSON::Any
        lookup_array(source).each do |parent|
          children = parent.as_h?.try(&.[subkey]?)
          if children.nil?
            raise "subelements: '#{subkey}' not found" unless skip_missing
            next
          end
          lookup_array(children).each { |child| result << JSON::Any.new([parent, child]) }
        end
        result.to_json
      end

      private def evaluate_csvfile_lookup(raw_arg : String) : String
        tokens = raw_arg.strip.split(/\s+/)
        key = tokens[0]?
        return "undefined" unless key

        opts = Hash(String, String).new
        tokens[1..].each do |token|
          k, sep, v = token.partition('=')
          opts[k] = v unless sep.empty?
        end

        file = opts["file"]?
        return "undefined" unless file
        delimiter = opts["delimiter"]? || ","
        col = opts["col"]?.try(&.to_i) || 1

        begin
          File.each_line(file) do |line|
            fields = line.split(delimiter)
            next unless fields[0]?.try(&.strip) == key
            return (fields[col]? || "").strip
          end
        rescue
        end
        "undefined"
      end

      private def evaluate_ini_lookup(raw_arg : String) : String
        tokens = raw_arg.strip.split(/\s+/)
        value_key = tokens[0]?
        return "undefined" unless value_key

        opts = Hash(String, String).new
        tokens[1..].each do |token|
          k, sep, v = token.partition('=')
          opts[k] = v unless sep.empty?
        end

        file = opts["file"]?
        return "undefined" unless file
        wanted_section = opts["section"]? || "DEFAULT"

        begin
          current_section = "DEFAULT"
          File.each_line(file) do |raw_line|
            line = raw_line.strip
            next if line.empty? || line.starts_with?(';') || line.starts_with?('#')
            if line.starts_with?('[') && line.ends_with?(']')
              current_section = line[1..-2]
              next
            end
            next unless current_section == wanted_section
            k, sep, v = line.partition('=')
            return v.strip if sep != "" && k.strip == value_key
          end
        rescue
        end
        "undefined"
      end

      private def evaluate_sequence_lookup(raw_arg : String) : String
        tokens, opts = parse_sequence_opts(raw_arg)
        tokens.each do |token|
          key, sep, val = token.partition('=')
          opts[key] = val unless sep.empty?
        end

        start = opts["start"]?.try(&.to_i) || 1
        stride = opts["stride"]?.try(&.to_i) || 1
        count = opts["count"]?.try(&.to_i)
        finish = opts["end"]?.try(&.to_i)
        format = opts["format"]?

        total = count || (finish ? ((finish - start) // stride) + 1 : 1)
        return "undefined" if total < 0

        values = (0...total).map { |i| start + i * stride }
        sequence_formatted_values(values, format)
      end

      # Splits the sequence lookup's raw argument into its remaining
      # tokens and an opts hash, handling the shorthand positional
      # "start-end" form (`lookup('sequence', '1-5')`), real Ansible's
      # own alternate spelling - only when the whole first token has no
      # "=" at all, so it doesn't collide with the key=value form's own
      # values (a format= string could itself contain a literal "-").
      private def parse_sequence_opts(raw_arg : String) : {Array(String), Hash(String, String)}
        tokens = raw_arg.strip.split(/\s+/)
        opts = Hash(String, String).new
        if tokens[0]? && !tokens[0].includes?('=') && (range_match = tokens[0].match(/^(\d+)-(\d+)$/))
          opts["start"] = range_match[1]
          opts["end"] = range_match[2]
          tokens = tokens[1..]
        end
        {tokens, opts}
      end

      private def sequence_formatted_values(values : Array(Int32), format : String?) : String
        formatted = format ? values.map { |v| (format % v) rescue v.to_s } : values.map(&.to_s)
        formatted.to_json
      end

      # real Ansible's password lookup default charset (ascii_letters +
      # digits + ".,:-_", its own `DEFAULT_PASSWORD_CHARS`) and default
      # length (20).
      PASSWORD_CHARS  = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a + [".", ",", ":", "-", "_"]
      PASSWORD_LENGTH = 20

      private def evaluate_password_lookup(raw_arg : String) : String
        tokens = raw_arg.strip.split(/\s+/)
        path = tokens[0]?
        return "undefined" unless path
        resolved_path = resolve_lookup_path(path)

        length = PASSWORD_LENGTH
        tokens[1..].each do |token|
          if token.starts_with?("length=")
            length = token[7..].to_i? || length
          end
        end

        # `/dev/null` is real Ansible's own documented idiom for "give me
        # a fresh random password and DON'T persist it" - its password
        # lookup plugin special-cases that path (`if path == '/dev/null'`
        # it skips both the read-back and the write). Without the
        # special case the generic "file exists -> read it back" branch
        # below wins, because /dev/null does exist and reads as the empty
        # string, so every `lookup('password', '/dev/null')` returned ""
        # instead of a password. Found live on imntreal.smallstep_ca,
        # whose CA/provisioner passwords come from exactly this idiom:
        # the role then wrote two EMPTY password files and `step ca init
        # --password-file=<empty>` fell back to prompting for one
        # interactively - which is what actually made that role fail
        # under this engine while real ansible-playbook ran it clean.
        if path == "/dev/null"
          return Array.new(length) { PASSWORD_CHARS.sample(Random::Secure) }.join
        end

        if File.exists?(resolved_path)
          return File.read(resolved_path).chomp
        end

        password = Array.new(length) { PASSWORD_CHARS.sample(Random::Secure) }.join
        begin
          dir = File.dirname(resolved_path)
          Dir.mkdir_p(dir) unless Dir.exists?(dir)
          # 0600, chmod BEFORE the bytes land - real Ansible's password
          # lookup also stores generated passwords owner-only; a default
          # 0644 lets any local user read the password while it persists.
          File.open(resolved_path, "w") do |io|
            io.chmod(0o600)
            io.write((password + "\n").to_slice)
          end
        rescue
        end
        password
      end
    end
  end
end
