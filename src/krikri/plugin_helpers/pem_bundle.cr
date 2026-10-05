require "json"

module Krikri
  module PluginHelpers
    # PemBundle.key_first - reorders the PEM blocks of `openssl pkcs12`
    # output so the private key comes first, matching the Ansible module's
    # parse output ([privatekey, certificate, other certificates]).
    # A block counts as the key ONLY from its `-----BEGIN <LABEL>-----`
    # header line, when the label ends in "PRIVATE KEY" (covers PRIVATE
    # KEY, RSA PRIVATE KEY, EC PRIVATE KEY, ENCRYPTED PRIVATE KEY).
    # The base64 body is never examined: certificate base64 contains the
    # letters "KEY" by chance in a small but real fraction of certificates,
    # which used to make that certificate sort before the actual key.
    # Relative order within keys and within non-keys is preserved
    # explicitly (partition, then concat), not via sort_by stability.
    module PemBundle
      def self.key_first(dump : String) : String?
        blocks = [] of Tuple(Bool, String)
        scanner = dump
        while start = scanner.index("-----BEGIN ")
          stop = scanner.index("-----END ", start)
          break unless stop
          line_end = scanner.index('\n', stop)
          block = scanner[start...(line_end || scanner.size)]
          blocks << {key_block?(block), block}
          scanner = scanner[(line_end || scanner.size)..]
        end
        return nil if blocks.empty?
        # Each block is newline-terminated in the Ansible module's output;
        # extract_block cuts before the '\n', so re-join with separators
        # and a trailing newline.
        keys, others = blocks.partition { |is_key, _| is_key }
        (keys + others).map { |_, pem_block| pem_block + "\n" }.join
      end

      private def self.key_block?(block : String) : Bool
        header = block.lines.find { |line| line.starts_with?("-----BEGIN ") }
        return false unless header
        label = header.lchop("-----BEGIN ").rchop("-----")
        label.ends_with?("PRIVATE KEY")
      end
    end
  end
end
