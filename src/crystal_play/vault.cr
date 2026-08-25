require "openssl"
require "openssl/hmac"
require "json"
require "yaml"

module CrystalPlay
  # Vault - Ansible Vault (AES256) encrypt/decrypt.
  #
  # File format (verified against real `ansible-vault`, not assumed from
  # memory):
  #   $ANSIBLE_VAULT;1.1;AES256
  #   <hex, wrapped at 80 columns>
  #
  # Where the wrapped hex, once unwrapped and hex-decoded, is itself ASCII
  # text: "<hex(salt)>\n<hex(hmac)>\n<hex(ciphertext)>". That's a
  # deliberate double hex-encoding, not a bug - Ansible's own format does
  # this. salt is 32 random bytes; a single PBKDF2-HMAC-SHA256 call over
  # (password, salt, 10_000 iterations, 80-byte output) is split into a
  # 32-byte AES key, a 32-byte HMAC key, and a 16-byte CTR IV; the
  # plaintext is PKCS7-padded to a 16-byte boundary before AES-256-CTR
  # encryption; the HMAC is computed over the ciphertext (encrypt-then-MAC)
  # using the derived HMAC key.
  module Vault
    HEADER_PREFIX = "$ANSIBLE_VAULT;"
    PBKDF2_ROUNDS = 10_000
    SALT_SIZE     =     32
    DERIVED_SIZE  =     80 # 32 (AES key) + 32 (HMAC key) + 16 (IV)
    BLOCK_SIZE    =     16
    WRAP_COLUMN   =     80

    class Error < Exception
    end

    # The vault password for this run, set once from --vault-password-file
    # or --ask-vault-pass before any playbook/role/task/vars file is read.
    # A single session-wide password (rather than threading one through
    # every file-loading call site individually - PlaybookParser,
    # RoleLoader, TaskExecutor's dynamic include_tasks: loader) matches how
    # Ansible itself treats the vault password: one secret for the run,
    # not a per-file argument.
    @@password : String? = nil
    # --vault-id label@source: several passwords, each tagged with the
    # identity it belongs to. A 1.2-format header names the identity it
    # was encrypted with ("$ANSIBLE_VAULT;1.2;AES256;dev"), so that one
    # is tried first; the rest are tried afterwards, which is what real
    # Ansible does and what makes an unlabeled or mislabeled blob still
    # decrypt when any supplied identity fits.
    @@vault_ids = Hash(String, String).new

    def self.password=(value : String?)
      @@password = value
    end

    def self.add_vault_id(label : String, secret : String) : Nil
      @@vault_ids[label] = secret
      # The first identity also serves as the single-password fallback,
      # so everything that predates --vault-id keeps working.
      @@password ||= secret
    end

    def self.vault_ids : Hash(String, String)
      @@vault_ids
    end

    # Every password worth trying for *content*, best candidate first.
    def self.candidate_passwords(content : String) : Array(String)
      candidates = [] of String

      # Header form: $ANSIBLE_VAULT;1.2;AES256;<label>
      header = content.lstrip.lines.first?
      if header && (parts = header.split(';')).size >= 4
        label = parts[3].strip
        @@vault_ids[label]?.try { |secret| candidates << secret }
      end

      @@vault_ids.each_value { |secret| candidates << secret unless candidates.includes?(secret) }
      @@password.try { |secret| candidates << secret unless candidates.includes?(secret) }
      candidates
    end

    def self.password : String?
      @@password
    end

    # True if `content` looks like an Ansible Vault-armored file/string
    # (starts with the "$ANSIBLE_VAULT;" header), independent of whether
    # its cipher/version are ones we actually support.
    def self.encrypted?(content : String) : Bool
      content.starts_with?(HEADER_PREFIX)
    end

    # Decrypts `content` if it's vault-encrypted (using the configured
    # password), otherwise returns it unchanged. This is what every
    # file-loading call site should call instead of using the raw file
    # content directly.
    def self.maybe_decrypt(content : String) : String
      return content unless encrypted?(content)

      candidates = candidate_passwords(content)
      if candidates.empty?
        raise Error.new("This content is vault-encrypted, but no vault password was provided (use --vault-password-file, --vault-id or --ask-vault-pass)")
      end

      last_error = nil
      candidates.each do |candidate|
        begin
          return decrypt(content, candidate)
        rescue ex
          last_error = ex
        end
      end

      raise last_error || Error.new("Unable to decrypt vault-encrypted content with any supplied vault password")
    end

    # Like maybe_decrypt, but for a parsed variable value rather than a raw
    # file - covers Ansible's other vault use case: a single value inline in
    # an otherwise-plaintext vars file, tagged `!vault` (what `ansible-vault
    # encrypt_string` produces, e.g. `db_password: !vault |`). Crystal's
    # YAML parser drops unknown tags and hands back the tagged scalar as a
    # plain string, so an inline-vault value already looks exactly like a
    # vault-encrypted file's content by the time it reaches here - the same
    # header check and decrypt() do the job. Recurses into arrays/hashes so
    # a vault-encrypted value nested inside a list or mapping var is also
    # caught.
    def self.maybe_decrypt_json(value : JSON::Any) : JSON::Any
      case raw = value.raw
      when String
        # A blob none of the supplied secrets can open is left AS IS
        # rather than aborting the parse. Real Ansible defers the
        # failure to the point of USE - a playbook carrying a prod-only
        # vault var still runs fine on a dev box with only the dev
        # secret, as long as no task actually references it. The
        # substitutor raises if such a value is ever rendered.
        if encrypted?(raw)
          begin
            JSON::Any.new(maybe_decrypt(raw))
          rescue
            value
          end
        else
          value
        end
      when Array
        JSON::Any.new(raw.map { |item| maybe_decrypt_json(item) })
      when Hash
        JSON::Any.new(raw.transform_values { |item| maybe_decrypt_json(item) })
      else
        value
      end
    end

    # Converts a YAML::Any value to JSON::Any, recursively stringifying
    # every hash key at every nesting level - unlike the `JSON.parse(
    # value.to_json)` round-trip used in several places in this codebase,
    # which crashes ("Can't convert Bool to a JSON object key") on a real,
    # supported Ansible/Jinja2 idiom: a dict keyed by a bare YAML boolean
    # (`true:`/`false:`/`yes:`/`no:`), which Python's own YAML loader
    # happily parses as a bool-keyed dict and Jinja2 happily indexes with
    # `dict[some_bool_expression]`. JSON has no non-string-key concept at
    # all, so crystal-ansible's own JSON::Any-based variable
    # representation stringifies the key ("true"/"false") instead -
    # meaning a role that then indexes such a dict with a boolean
    # expression needs that same "true"/"false" stringification applied
    # at lookup time too (see VariableLookup's own dotted/bracket-index
    # handling). Found benchmarking robertdebock.tailscale's own
    # `tailscale_sysctl_file`/`tailscale_command` vars, both keyed by a
    # bare boolean - the crash happened at PARSE time, before any task
    # ran, taking down the entire playbook.
    def self.yaml_value_to_json(value : YAML::Any) : JSON::Any
      case raw = value.raw
      when Hash
        result = Hash(String, JSON::Any).new
        raw.each { |k, v| result[stringify_yaml_key(k)] = yaml_value_to_json(v) }
        JSON::Any.new(result)
      when Array
        JSON::Any.new(raw.map { |item| yaml_value_to_json(item) })
      else
        JSON.parse(value.to_json)
      end
    end

    private def self.stringify_yaml_key(key : YAML::Any) : String
      case raw = key.raw
      when Bool
        raw.to_s
      else
        key.to_s
      end
    end

    def self.decrypt(content : String, password : String) : String
      lines = content.strip.lines
      raise Error.new("Not a vault-encrypted file (missing header)") if lines.empty?

      header = lines[0]
      raise Error.new("Not a vault-encrypted file (missing $ANSIBLE_VAULT header)") unless header.starts_with?(HEADER_PREFIX)

      cipher_name = header.split(";")[2]?
      raise Error.new("Unsupported vault cipher: #{cipher_name || "unknown"} (only AES256 is supported)") unless cipher_name == "AES256"

      wrapped_hex = lines[1..].join
      body = hex_decode(wrapped_hex)
      parts = String.new(body).split("\n")
      raise Error.new("Malformed vault content") unless parts.size == 3

      salt = hex_decode(parts[0])
      expected_hmac = parts[1]
      ciphertext = hex_decode(parts[2])

      key, hmac_key, iv = derive_keys(password, salt)

      computed_hmac = OpenSSL::HMAC.hexdigest(:sha256, hmac_key, ciphertext)
      unless constant_time_compare(computed_hmac, expected_hmac)
        raise Error.new("Vault decryption failed: HMAC mismatch (wrong password?)")
      end

      padded = aes_ctr(ciphertext, key, iv, encrypt: false)
      String.new(remove_pkcs7_padding(padded))
    end

    def self.encrypt(plaintext : String, password : String) : String
      salt = Random::Secure.random_bytes(SALT_SIZE)
      key, hmac_key, iv = derive_keys(password, salt)

      padded = add_pkcs7_padding(plaintext.to_slice)
      ciphertext = aes_ctr(padded, key, iv, encrypt: true)
      hmac_hex = OpenSSL::HMAC.hexdigest(:sha256, hmac_key, ciphertext)

      body = "#{salt.hexstring}\n#{hmac_hex}\n#{ciphertext.hexstring}"
      wrapped_hex = body.to_slice.hexstring

      String.build do |str|
        str << "#{HEADER_PREFIX}1.1;AES256\n"
        pos = 0
        while pos < wrapped_hex.size
          str << wrapped_hex.byte_slice(pos, Math.min(WRAP_COLUMN, wrapped_hex.size - pos)) << '\n'
          pos += WRAP_COLUMN
        end
      end
    end

    # PBKDF2-HMAC-SHA256(password, salt, 10_000, 80 bytes) split into
    # {aes_key(32), hmac_key(32), iv(16)}.
    private def self.derive_keys(password : String, salt : Bytes) : {Bytes, Bytes, Bytes}
      derived = OpenSSL::PKCS5.pbkdf2_hmac(password, salt, PBKDF2_ROUNDS, OpenSSL::Algorithm::SHA256, DERIVED_SIZE)
      {derived[0, 32], derived[32, 32], derived[64, 16]}
    end

    private def self.aes_ctr(data : Bytes, key : Bytes, iv : Bytes, encrypt : Bool) : Bytes
      cipher = OpenSSL::Cipher.new("aes-256-ctr")
      encrypt ? cipher.encrypt : cipher.decrypt
      cipher.key = key
      cipher.iv = iv

      io = IO::Memory.new
      io.write(cipher.update(data))
      io.write(cipher.final)
      io.to_slice
    end

    private def self.add_pkcs7_padding(data : Bytes) : Bytes
      pad_len = BLOCK_SIZE - (data.size % BLOCK_SIZE)
      data + Bytes.new(pad_len, pad_len.to_u8)
    end

    private def self.remove_pkcs7_padding(data : Bytes) : Bytes
      return data if data.empty?
      pad_len = data[-1].to_i
      raise Error.new("Vault decryption failed: invalid padding") if pad_len == 0 || pad_len > data.size
      data[0, data.size - pad_len]
    end

    private def self.hex_decode(hex : String) : Bytes
      hex = hex.strip
      raise Error.new("Malformed vault content: odd-length hex data") if hex.size.odd?
      Bytes.new(hex.size // 2) { |i| hex[i * 2, 2].to_u8(16) }
    rescue ex : ArgumentError
      raise Error.new("Malformed vault content: invalid hex data")
    end

    # Constant-time string comparison so a mistyped/wrong vault password
    # can't be distinguished from a corrupted file via response-time
    # side channels.
    private def self.constant_time_compare(a : String, b : String) : Bool
      return false if a.bytesize != b.bytesize
      result = 0
      a.each_byte.zip(b.each_byte) { |x, y| result |= (x ^ y) }
      result == 0
    end
  end
end
