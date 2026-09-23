module Krikri
  module PluginHelpers
    # AuthorizedKeysFile - pure logic for ensuring a public key line is
    # present/absent in an OpenSSH authorized_keys-style file, entirely
    # without I/O so it's unit-testable with plain strings.
    module AuthorizedKeysFile
      # The real module's own VALID_SSH2_KEY_TYPES (ansible.posix
      # authorized_key's parsekey): a line is a key line iff one of its
      # whitespace-separated tokens is exactly one of these.
      KEY_TYPES = %w(
        sk-ecdsa-sha2-nistp256@openssh.com
        sk-ecdsa-sha2-nistp256-cert-v01@openssh.com
        webauthn-sk-ecdsa-sha2-nistp256@openssh.com
        ecdsa-sha2-nistp256
        ecdsa-sha2-nistp256-cert-v01@openssh.com
        ecdsa-sha2-nistp384
        ecdsa-sha2-nistp384-cert-v01@openssh.com
        ecdsa-sha2-nistp521
        ecdsa-sha2-nistp521-cert-v01@openssh.com
        sk-ssh-ed25519@openssh.com
        sk-ssh-ed25519-cert-v01@openssh.com
        ssh-ed25519
        ssh-ed25519-cert-v01@openssh.com
        ssh-dss
        ssh-rsa
        ssh-xmss@openssh.com
        ssh-xmss-cert-v01@openssh.com
        rsa-sha2-256
        rsa-sha2-512
        ssh-rsa-cert-v01@openssh.com
        rsa-sha2-512-cert-v01@openssh.com
        ssh-dss-cert-v01@openssh.com
      )

      private record ParsedKey, options : Hash(String, String?), key_type : String, blob : String, comment : String

      # Extracts the "type base64blob" portion of a key line, ignoring any
      # leading options and trailing comment - that's what makes a key
      # unique, matching how sshd itself treats authorized_keys entries.
      # Returns nil for blank/comment/unparseable lines.
      def self.key_signature(line : String) : String?
        parsed = parse_key(line)
        parsed ? "#{parsed.key_type} #{parsed.blob}" : nil
      end

      # Ensures `key_line`'s signature is present (or absent) in `text`.
      # Returns {new_text, changed}.
      def self.ensure(text : String, key_line : String, present : Bool) : {String, Bool}
        ensure_keys(text, [key_line], present)
      end

      # Multi-key form mirroring the real module's enforce_state: each new
      # key is matched against the file by its blob (the real module's
      # parsekeys dict is keyed on the blob alone), and "already present"
      # means the whole parsed key matches - blob, type, OPTIONS DICT, and
      # comment. key_options are part of that comparison in the real
      # module (its parsed_new_key[:4] != existing_keys[blob][:4] check),
      # so adding key_options: to an existing bare key is a real change:
      # the old line is deleted and the options-prefixed line re-serialized
      # (moved to the end of the file, like the real module's
      # delete-then-reinsert). On any write the whole file is
      # re-serialized from its parsed keys, exactly like the real module's
      # serialize() pass. With `exclusive` (state present only), every
      # existing key whose blob isn't among the new keys is deleted - the
      # real module's "remove all other keys to honor exclusive".
      def self.ensure_keys(text : String, key_lines : Array(String), present : Bool, exclusive : Bool = false) : {String, Bool}
        lines = text.split("\n").reject(&.empty?)
        requested = key_lines.map { |line| parse_key(line) }
        result_lines = lines.dup

        if present
          changed = apply_present(result_lines, requested)
          if exclusive
            result_lines, removed = apply_exclusive(result_lines, requested)
            changed ||= removed
          end
        else
          blobs = requested.compact_map { |entry| entry.try(&.blob) }
          before = result_lines.size
          result_lines = result_lines.reject do |existing|
            (parsed = parse_key(existing)) && blobs.includes?(parsed.blob)
          end
          changed = result_lines.size != before
        end

        # Real Ansible writes the file by serializing every parsed key
        # through its canonical form (option dict -> "k,k=v " prefix,
        # "type blob comment" body) - and only when something changed (a
        # fully-matched run never touches the file, byte-for-byte).
        result_lines = canonicalize(result_lines) if changed

        {render(result_lines), changed}
      end

      # state=present without exclusive: for each requested key, a file
      # line with the same blob is either left alone (fully matching) or
      # replaced by the re-serialized requested key (moved to the end,
      # like the real module's delete-then-reinsert); an unmatched key is
      # appended at the end. Returns whether anything changed.
      private def self.apply_present(result_lines : Array(String), requested : Array(ParsedKey?)) : Bool
        changed = false
        requested.each do |new_key|
          next if new_key.nil?

          found_at = result_lines.index do |existing|
            (parsed = parse_key(existing)) && parsed.blob == new_key.blob
          end
          if found_at
            existing = parse_key(result_lines[found_at])
            next if existing && keys_match?(existing, new_key)

            result_lines.delete_at(found_at)
          end
          result_lines << serialize(new_key)
          changed = true
        end
        changed
      end

      # Real module's exclusive pass: drop every parsed key line whose
      # blob isn't among the requested keys. Returns the kept lines and
      # whether any line was dropped.
      private def self.apply_exclusive(result_lines : Array(String), requested : Array(ParsedKey?)) : {Array(String), Bool}
        blobs = requested.compact_map { |entry| entry.try(&.blob) }
        kept = result_lines.reject do |existing|
          (parsed = parse_key(existing)) && !blobs.includes?(parsed.blob)
        end
        {kept, kept.size != result_lines.size}
      end

      # Real module's match: everything but the parse rank - blob (already
      # equal by lookup), type, option dict (order-insensitive), comment.
      private def self.keys_match?(existing : ParsedKey, new_key : ParsedKey) : Bool
        existing.key_type == new_key.key_type &&
          existing.options == new_key.options &&
          existing.comment == new_key.comment
      end

      private def self.canonicalize(lines : Array(String)) : Array(String)
        lines.map do |existing|
          (parsed = parse_key(existing)) ? serialize(parsed) : existing
        end
      end

      # Mirrors the real module's parsekey: whitespace-split tokens (its
      # shlex runs with quotes disabled, so a quoted option chunk with
      # spaces just becomes several tokens later re-joined), the first
      # known key-type token ends the options prefix, the blob follows it,
      # and everything after the blob is the comment.
      private def self.parse_key(line : String) : ParsedKey?
        stripped = line.strip
        return nil if stripped.empty? || stripped.starts_with?("#")

        tokens = stripped.split
        index = tokens.index { |token| KEY_TYPES.includes?(token) }
        return nil unless index
        return nil if index + 1 >= tokens.size

        options = index > 0 ? parse_options(tokens[0...index].join(" ")) : {} of String => String?
        blob = tokens[index + 1]
        comment = index + 2 < tokens.size ? tokens[(index + 2)..].join(" ") : ""
        ParsedKey.new(options, tokens[index], blob, comment)
      end

      # Mirrors the real module's parseoptions: split on commas that
      # aren't inside quotes, then "k=v" pairs (value kept verbatim,
      # quotes included) and bare "k" flags.
      private def self.parse_options(options : String) : Hash(String, String?)
        parts = split_outside_quotes(options)
        result = {} of String => String?
        parts.reject(&.empty?).each do |part|
          if eq = part.index('=')
            result[part[0...eq]] = part[(eq + 1)..]
          else
            result[part] = nil
          end
        end
        result
      end

      private def self.split_outside_quotes(options : String) : Array(String)
        parts = [] of String
        current = IO::Memory.new
        quote = nil
        options.each_char do |character|
          if quote
            quote = nil if character == quote
            current << character
          elsif character == '"' || character == '\''
            quote = character
            current << character
          elsif character == ','
            parts << current.to_s
            current.clear
          else
            current << character
          end
        end
        parts << current.to_s
        parts
      end

      # Mirrors the real module's serialize: options comma-joined (bare
      # flags vs k=v) followed by a space, then "type blob comment". The
      # comment-less line really does end with a trailing space in the
      # real module's output ("...%s %s %s\n" with an empty comment) -
      # reproduced here byte-for-byte.
      private def self.serialize(key : ParsedKey) : String
        option_str = ""
        unless key.options.empty?
          option_str = key.options.map { |name, value| value ? "#{name}=#{value}" : name }.join(",") + " "
        end
        "#{option_str}#{key.key_type} #{key.blob} #{key.comment}"
      end

      private def self.render(lines : Array(String)) : String
        return "" if lines.empty?
        lines.join("\n") + "\n"
      end
    end
  end
end
