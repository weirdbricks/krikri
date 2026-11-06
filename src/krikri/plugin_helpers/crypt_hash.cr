require "json"

module Krikri
  module PluginHelpers
    # ansible-core 2.21's password_hash backend. `module_utils/utils/encrypt.py`
    # swapped passlib for libxcrypt (libc `crypt()` + `crypt_gensalt()`), so a
    # salted hash now comes from the controller's own C library instead of a
    # Python reimplementation. That changes observable output for a
    # user-supplied salt: libxcrypt re-encodes the salt bytes with crypt's
    # base64 and always writes the scheme's rounds/cost marker, where passlib
    # used the salt text verbatim.
    #
    # This mirrors `CryptHash` from that module (algorithm table, salt/size
    # rules, error strings) and calls the same libcrypt entry points, so the
    # hashes match what real Ansible produces on the same host.
    module CryptHash
      @[Link("crypt")]
      lib LibCrypt
        fun crypt(key : UInt8*, salt : UInt8*) : UInt8*
        fun crypt_gensalt(prefix : UInt8*, count : UInt64, rbytes : UInt8*, nrbytes : LibC::Int) : UInt8*
      end

      record Algo,
        crypt_id : String,
        salt_size : Int32,
        implicit_rounds : Int64?,
        salt_exact : Bool,
        implicit_ident : String?,
        rounds_format : String?,
        requires_gensalt : Bool

      # encrypt.py's BaseHash.algorithms + CryptHash's own addition.
      ALGORITHMS = {
        "md5_crypt"    => Algo.new("1", 8, nil, false, nil, nil, false),
        "bcrypt"       => Algo.new("2b", 22, 12_i64, true, "2b", "cost", false),
        "sha256_crypt" => Algo.new("5", 16, 535000_i64, false, nil, "rounds", false),
        "sha512_crypt" => Algo.new("6", 16, 656000_i64, false, nil, "rounds", false),
        "yescrypt"     => Algo.new("y", 16, 5_i64, true, nil, "cost", true),
      }

      # The filter's own passlib-era name mapping (core.py's
      # get_encrypted_password) and the message it raises for a name it does
      # not know.
      FILTER_NAMES = {
        "md5"      => "md5_crypt",
        "blowfish" => "bcrypt",
        "sha256"   => "sha256_crypt",
        "sha512"   => "sha512_crypt",
      }
      FILTER_ERROR_LIST = "md5, blowfish, sha256, sha512"

      def self.supported?(algorithm : String) : Bool
        ALGORITHMS.has_key?(algorithm)
      end

      # get_encrypted_password(): the filter-level name mapping plus its own
      # rejection of anything outside the passlib-era set (live-verified vs
      # 2.21.6, whose controller has passlib installed - without it the name
      # reaches do_encrypt and fails with the crypt wording instead).
      def self.filter_password_hash(secret : String, hashtype : String, salt : String? = nil,
                                    salt_size : JSON::Any? = nil, rounds : JSON::Any? = nil,
                                    ident : String? = nil) : String
        algorithm = FILTER_NAMES[hashtype]? || hashtype
        # Both the mapping's KEYS and its VALUES pass ('md5_crypt' and
        # 'bcrypt' spelled out are fine); everything else - yescrypt
        # included, even though the crypt backend supports it - is
        # rejected here (live-verified vs 2.21.6).
        unless FILTER_NAMES.has_value?(algorithm) || FILTER_NAMES.has_key?(algorithm)
          raise "#{algorithm} is not in the list of supported passlib algorithms: #{FILTER_ERROR_LIST}"
        end
        hash(secret, algorithm, salt, salt_size, rounds, ident)
      end

      # CryptHash.hash(): rounds/ident defaults, salt string generation, then
      # libcrypt's own crypt().
      def self.hash(secret : String, algorithm : String, salt : String? = nil,
                    salt_size : JSON::Any? = nil, rounds : JSON::Any? = nil,
                    ident : String? = nil) : String
        algo = ALGORITHMS[algorithm]?
        raise "crypt does not support '#{algorithm}' algorithm" unless algo

        rounds_n = rounds_value(rounds) || algo.implicit_rounds
        ident_n = ident && !ident.empty? ? ident : algo.crypt_id
        saltstring = gensalt(algorithm, algo, ident_n, rounds_n, salt, salt_size)

        result = LibCrypt.crypt(secret.to_unsafe, saltstring.to_unsafe)
        hash = result.null? ? "" : String.new(result)
        if hash.empty? || hash.starts_with?('*')
          raise "crypt does not support '#{algorithm}' algorithm"
        end
        hash
      end

      private def self.rounds_value(rounds : JSON::Any?) : Int64?
        return nil if rounds.nil?
        case raw = rounds.raw
        when Nil     then nil
        when Bool    then raw ? 1_i64 : nil
        when Int64   then raw.zero? ? nil : raw
        when Float64
          # crypt_gensalt's count parameter is a C integer: passlib's
          # integer coercion used to accept these, libxcrypt's binding does
          # not (live-verified vs 2.21.6 for both spellings).
          raise "argument 2: TypeError: 'float' object cannot be interpreted as an integer"
        when String
          return nil if raw.empty?
          raise "argument 2: TypeError: 'str' object cannot be interpreted as an integer"
        else
          nil
        end
      end

      # `_gensalt`: a missing salt means random bytes of the scheme's size; a
      # given one is validated and used as-is. libxcrypt's crypt_gensalt
      # encodes the bytes (crypt base64) and adds the rounds/cost marker.
      private def self.gensalt(algorithm : String, algo : Algo, ident : String,
                               rounds : Int64?, salt : String?, salt_size : JSON::Any?) : String
        rbytes = if salt.nil? || salt.empty?
                   Random::Secure.random_bytes(validate_salt_size(algorithm, algo, salt_size))
                 else
                   validate_salt(algorithm, algo, salt, salt_size).to_slice
                 end

        prefix = "$#{ident}$"
        result = LibCrypt.crypt_gensalt(prefix.to_unsafe, (rounds || 0).to_u64, rbytes.to_unsafe, rbytes.size)
        if result.null?
          # AnsibleError(...) from the ValueError: the displayed text keeps
          # the cause appended (live-verified: an md5_crypt hash asked for
          # rounds reads exactly like this).
          raise "Failed to generate salt for '#{algorithm}' algorithm: crypt_gensalt failed: unable to generate salt"
        end
        String.new(result)
      end

      private def self.validate_salt_size(algorithm : String, algo : Algo, salt_size : JSON::Any?) : Int32
        size = if salt_size.nil?
                 algo.salt_size
               else
                 case raw = salt_size.raw
                 when Nil     then algo.salt_size
                 when Int64   then raw.zero? ? algo.salt_size : raw.to_i32
                 when Bool    then raw ? 1 : algo.salt_size
                 when Float64 then raw.to_i32
                 else
                   raise "salt_size must be an integer"
                 end
               end
        if algo.salt_exact && size != algo.salt_size
          raise "invalid salt size supplied (#{size}), expected #{algo.salt_size}"
        elsif !algo.salt_exact && size > algo.salt_size
          raise "invalid salt size supplied (#{size}), expected at most #{algo.salt_size}"
        end
        size
      end

      private def self.validate_salt(algorithm : String, algo : Algo, salt : String,
                                     salt_size : JSON::Any?) : String
        validate_salt_size(algorithm, algo, salt_size)
        unless salt.matches?(/\A[.\/A-Za-z0-9]+\z/)
          raise "invalid characters in salt"
        end
        if algo.salt_exact && salt.size != algo.salt_size
          raise "invalid salt size supplied (#{salt.size}), expected #{algo.salt_size}"
        elsif !algo.salt_exact && salt.size > algo.salt_size
          raise "invalid salt size supplied (#{salt.size}), expected at most #{algo.salt_size}"
        end
        salt
      end
    end
  end
end
