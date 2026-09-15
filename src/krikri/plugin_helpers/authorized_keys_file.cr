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
        ensure_keys(text, [key_line], present)
      end

      # Multi-key form matching the real module's enforce_state: each key
      # line is matched by its own signature; new keys are appended after
      # existing ones in the order given. With `exclusive` (state present
      # only), every existing key whose signature isn't among the new keys
      # is deleted - real Ansible's "remove all other keys to honor
      # exclusive".
      def self.ensure_keys(text : String, key_lines : Array(String), present : Bool, exclusive : Bool = false) : {String, Bool}
        signatures = key_lines.map { |line| key_signature(line) }
        lines = text.split("\n").reject(&.empty?)

        if present
          result_lines = lines.dup
          changed = false
          key_lines.each_with_index do |line, i|
            signature = signatures[i]
            next if signature.nil?
            next if result_lines.any? { |existing| key_signature(existing) == signature }

            result_lines << line.strip
            changed = true
          end
          if exclusive
            kept = result_lines.reject do |existing|
              existing_sig = key_signature(existing)
              existing_sig && !signatures.includes?(existing_sig)
            end
            changed ||= kept.size != result_lines.size
            result_lines = kept
          end
          {render(result_lines), changed}
        else
          kept = lines.reject { |existing| (sig = key_signature(existing)) && signatures.includes?(sig) }
          {render(kept), kept.size != lines.size}
        end
      end

      private def self.render(lines : Array(String)) : String
        return "" if lines.empty?
        lines.join("\n") + "\n"
      end
    end
  end
end
