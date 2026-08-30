module Krikri
  module PluginHelpers
    # AuthorizedKeysFile - pure logic for ensuring a public key line is
    # present/absent in an OpenSSH authorized_keys-style file, entirely
    # without I/O so it's unit-testable with plain strings.
    module AuthorizedKeysFile
      KEY_TYPES = %w(ssh-rsa ssh-dss ssh-ed25519 ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521)

      # Extracts the "type base64blob" portion of a key line, ignoring any
      # leading options and trailing comment - that's what makes a key
      # unique, matching how sshd itself treats authorized_keys entries.
      # Returns nil for blank/comment/unparseable lines.
      def self.key_signature(line : String) : String?
        stripped = line.strip
        return nil if stripped.empty? || stripped.starts_with?("#")

        tokens = stripped.split
        index = tokens.index { |token| KEY_TYPES.includes?(token) }
        return nil unless index
        return nil if index + 1 >= tokens.size

        "#{tokens[index]} #{tokens[index + 1]}"
      end

      # Ensures `key_line`'s signature is present (or absent) in `text`.
      # Returns {new_text, changed}.
      def self.ensure(text : String, key_line : String, present : Bool) : {String, Bool}
        signature = key_signature(key_line)
        lines = text.split("\n").reject(&.empty?)

        if present
          add(lines, key_line, signature)
        else
          remove(lines, signature)
        end
      end

      private def self.add(lines : Array(String), key_line : String, signature : String?) : {String, Bool}
        return {render(lines), false} if lines.any? { |existing| key_signature(existing) == signature }

        {render(lines + [key_line.strip]), true}
      end

      private def self.remove(lines : Array(String), signature : String?) : {String, Bool}
        kept = lines.reject { |existing| key_signature(existing) == signature }
        {render(kept), kept.size != lines.size}
      end

      private def self.render(lines : Array(String)) : String
        return "" if lines.empty?
        lines.join("\n") + "\n"
      end
    end
  end
end
