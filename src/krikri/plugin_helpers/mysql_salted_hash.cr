require "digest/sha256"

module Krikri
  module PluginHelpers
    # ansible.mysql 5.2.0's implementations/mysql/hash.py - the
    # SHA-crypt-derived storage format MySQL's caching_sha2_password /
    # sha256_password plugins store, made DETERMINISTIC by the module's
    # `salt:` parameter (`$A$005$<salt><base64 digest>`, hexed for the
    # `AS 0x...` CREATE/ALTER form). Real relies on the determinism for
    # idempotency: user.py compares mysql.user.authentication_string
    # against mysql_sha256_password_hash(plugin_auth_string, salt)
    # before deciding whether an ALTER is needed (wiggels.snipeit's own
    # "Create snipeit user" task, round 1500042, reported changed on
    # every warm run without this - the server's own random-salt hash
    # never equals the plaintext it was asked to store).
    #
    # The digest walk is Drepper's SHA-crypt exactly as the Python port
    # writes it (5 * 1000 iterations), pinned against that Python
    # implementation's own output in test/unit/mysql_salted_hash_test.cr.
    module MysqlSaltedHash
      extend self

      # The stored (raw) hash for a (password, salt) pair. The salt is
      # the module's validated 20-character value; the caller's salt
      # check ("salt must be 20 characters long") runs first in real,
      # so no length guard is repeated here.
      def hash(password : String, salt : String) : String
        digest = sha_crypt_base64(password.to_slice, salt.to_slice, 5000)
        "$A$005$#{salt}#{digest}"
      end

      # The same bytes upper-cased as hex - the literal MySQL accepts
      # after `IDENTIFIED WITH <plugin> AS 0x`.
      def hash_hex(password : String, salt : String) : String
        hash(password, salt).bytes.map { |byte| byte.to_s(16).rjust(2, '0') }.join.upcase
      end

      # sha_crypt's digest walk over binary buffers - the Python
      # original builds one immutable bytes blob per step, mirrored here
      # with one IO::Memory per step.
      private def sha_crypt_base64(key : Bytes, salt : Bytes, loops : Int32) : String
        num_bytes = 32
        digest_b = concat_sha256([key, salt, key])

        # key + salt, then digest_b repeatedly truncated to the remaining
        # key length (Python's `for i in range(len(key), 0, -num_bytes)`).
        step = IO::Memory.new
        step.write(key)
        step.write(salt)
        i = key.size
        while i > 0
          step.write(i > num_bytes ? digest_b : digest_b[0, i])
          i -= num_bytes
        end

        # Then one bit at a time: digest_b for each set bit of the key
        # length, the key otherwise.
        i = key.size
        while i > 0
          step.write((i & 1) != 0 ? digest_b : key)
          i >>= 1
        end
        digest_a = Digest::SHA256.digest(step.to_slice)

        key_stream = IO::Memory.new
        key.size.times { key_stream.write(key) }
        digest_dp = Digest::SHA256.digest(key_stream.to_slice)

        byte_sequence_p = IO::Memory.new
        i = key.size
        while i > 0
          byte_sequence_p.write(i > num_bytes ? digest_dp : digest_dp[0, i])
          i -= num_bytes
        end

        salt_stream = IO::Memory.new
        (16 + digest_a[0]).times { salt_stream.write(salt) }
        digest_ds = Digest::SHA256.digest(salt_stream.to_slice)

        byte_sequence_s = IO::Memory.new
        i = salt.size
        while i > 0
          byte_sequence_s.write(i > num_bytes ? digest_ds : digest_ds[0, i])
          i -= num_bytes
        end

        to64_shuffle(sha_crypt_rounds(digest_a, byte_sequence_p.to_slice, byte_sequence_s.to_slice, loops))
      end

      # The 5 * 1000 mixing rounds: each round hashes a block built from
      # the two byte sequences and the running digest, alternating roles
      # on the round index's low bit and its divisibility by 3 and 7
      # exactly as the Python port does.
      private def sha_crypt_rounds(digest_a : Bytes, byte_sequence_p : Bytes, byte_sequence_s : Bytes, loops : Int32) : Bytes
        digest_c = digest_a
        loops.times do |iteration|
          block = IO::Memory.new
          block.write((iteration & 1) != 0 ? byte_sequence_p : digest_c)
          block.write(byte_sequence_s) if iteration % 3 != 0
          block.write(byte_sequence_p) if iteration % 7 != 0
          block.write((iteration & 1) != 0 ? digest_c : byte_sequence_p)
          digest_c = Digest::SHA256.digest(block.to_slice)
        end
        digest_c
      end

      # The _to64 shuffle: 10/21/30 stepping over the 32-byte digest
      # in 4-char groups, then a final 3-char group from the tail
      # bytes.
      private def to64_shuffle(digest_c : Bytes) : String
        result = String::Builder.new
        i = 0
        loop do
          result << to64((digest_c[i].to_i << 16) | (digest_c[(i + 10) % 30].to_i << 8) | digest_c[(i + 20) % 30].to_i, 4)
          i = (i + 21) % 30
          break if i == 0
        end
        result << to64((digest_c[31].to_i << 8) | digest_c[30].to_i, 3)
        result.to_s
      end

      # Python's _to64: the low 6 bits of value as one character of the
      # SHA-crypt base-64 alphabet, count times (little-endian within
      # the group), exactly as the Python port indexes it.
      private def to64(value : Int32, count : Int32) : String
        alphabet = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        result = String::Builder.new
        v = value
        count.times do
          result << alphabet[v & 0x3F]
          v >>= 6
        end
        result.to_s
      end

      private def concat_sha256(parts : Array(Bytes)) : Bytes
        io = IO::Memory.new
        parts.each { |part| io.write(part) }
        Digest::SHA256.digest(io.to_slice)
      end
    end
  end
end
