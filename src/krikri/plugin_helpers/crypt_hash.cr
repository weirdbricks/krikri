require "json"
require "random/secure"

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
    #
    # The library is loaded at RUNTIME (dlopen), never linked in: ansible's own
    # `_internal/_encryption/_crypt.py` CryptFacade does exactly that (via
    # ctypes), probes the same libraries in the same order, and DEGRADES
    # gracefully when `crypt_gensalt` is missing (it builds the salt string by
    # hand instead, and rejects yescrypt). A build-time `@[Link("crypt")]`
    # instead broke every release build: macOS has no libcrypt at all
    # (`ld: library 'crypt' not found`) and Alpine ships only an 8-byte empty
    # libcrypt.a stub, so the musl-static Linux link died on `undefined
    # reference to crypt_gensalt`.
    module CryptHash
      # The runtime half: which crypt library got loaded, and whether it is
      # libxcrypt (has crypt_gensalt) or a bare libc crypt() (musl).
      class CryptFacade
        # libxcrypt's own struct crypt_data is small, but musl's crypt_r
        # expects ~128K of it and ansible allocates that size, so match it.
        CRYPT_DATA_SIZE = 131_072
        # ansible's own output buffer for crypt_gensalt_rn.
        GENSALT_OUTPUT_SIZE = 256
        # crypt(3)'s "invalid salt"/"unsupported scheme" return values.
        FAILURE_TOKENS = {"*", "*0", "*1"}

        alias CryptFn = (UInt8*, UInt8*) -> UInt8*
        alias CryptRFn = (UInt8*, UInt8*, UInt8*) -> UInt8*
        alias GensaltFn = (UInt8*, UInt64, UInt8*, LibC::Int) -> UInt8*
        alias GensaltRnFn = (UInt8*, UInt64, UInt8*, LibC::Int, UInt8*, LibC::Int) -> UInt8*

        # Same order as ansible's `_CRYPT_LIBS`: libxcrypt by soname first,
        # then (non-darwin only) the process's own libc - where a musl host's
        # crypt() lives - then macOS's two Homebrew libxcrypt paths. The
        # musl-specific sonames stand in for ansible's bare `ctypes.CDLL(None)`:
        # dlopen'ing a glibc libc.so by name into a *static musl* process would
        # initialize a second libc, which is not something to risk.
        CANDIDATE_LIBRARIES = begin
          libs = ["libcrypt.so.1", "libcrypt.dylib", "libcrypt.so"] of String?
          {% if flag?(:darwin) %}
            libs.concat([
              "/opt/homebrew/opt/libxcrypt/lib/libcrypt.dylib",
              "/usr/local/opt/libxcrypt/lib/libcrypt.dylib",
            ])
          {% else %}
            libs << nil
            libs.concat([
              "libc.musl-x86_64.so.1",
              "libc.musl-aarch64.so.1",
              "libc.musl-riscv64.so.1",
            ])
          {% end %}
          libs
        end

        # Test seam (and the only reason this is a property): a spec can point
        # the module at a facade built from a specific library list.
        class_property current : CryptFacade?

        def self.facade : CryptFacade
          current || (self.current = new)
        end

        @crypt_plain : CryptFn?
        @crypt_r : CryptRFn?
        @gensalt_plain : GensaltFn?
        @gensalt_rn : GensaltRnFn?

        def initialize(lib_names : Array(String?) = CANDIDATE_LIBRARIES, use_gensalt : Bool = true)
          @crypt_plain = nil
          @crypt_r = nil
          @gensalt_plain = nil
          @gensalt_rn = nil
          load_library(lib_names, use_gensalt)
        end

        # Ansible's HAS_CRYPT: no library at all means password_hash cannot be
        # used on this host.
        def available? : Bool
          !@crypt_r.nil? || !@crypt_plain.nil?
        end

        # Ansible's `_crypt_facade.has_crypt_gensalt`: false on a musl host, so
        # the salt string gets built by hand instead of by libxcrypt.
        def has_crypt_gensalt? : Bool
          !@gensalt_rn.nil? || !@gensalt_plain.nil?
        end

        # crypt(): nil for every outcome ansible turns into an error (a null
        # pointer, an empty string, or crypt's "*" failure tokens).
        def crypt(word : String, salt : String) : String?
          result =
            if fn = @crypt_r
              # crypt_r requires a zeroed struct crypt_data on first use.
              data = Bytes.new(CRYPT_DATA_SIZE, 0_u8)
              fn.call(word.to_unsafe, salt.to_unsafe, data.to_unsafe)
            elsif fn = @crypt_plain
              fn.call(word.to_unsafe, salt.to_unsafe)
            else
              Pointer(UInt8).null
            end
          return nil if result.null?
          text = String.new(result)
          return nil if text.empty? || FAILURE_TOKENS.includes?(text)
          text
        end

        # crypt_gensalt(): nil when the library has no gensalt entry point at
        # all or when it refuses the prefix/rounds.
        def crypt_gensalt(prefix : String, count : UInt64, rbytes : Bytes) : String?
          result =
            if fn = @gensalt_rn
              output = Bytes.new(GENSALT_OUTPUT_SIZE, 0_u8)
              returned = fn.call(prefix.to_unsafe, count, rbytes.to_unsafe, rbytes.size,
                output.to_unsafe, output.size)
              returned.null? ? Pointer(UInt8).null : output.to_unsafe
            elsif fn = @gensalt_plain
              fn.call(prefix.to_unsafe, count, rbytes.to_unsafe, rbytes.size)
            else
              Pointer(UInt8).null
            end
          return nil if result.null?
          text = String.new(result)
          return nil if text.empty? || FAILURE_TOKENS.includes?(text)
          text
        end

        # `use_gensalt: false` reproduces a crypt library without
        # crypt_gensalt (what musl libc gives ansible) - no library on a glibc
        # host can, so the specs use it to exercise the fallback.
        private def load_library(lib_names : Array(String?), use_gensalt : Bool) : Nil
          lib_names.each do |name|
            # A nil name means "the main program handle" (ansible's bare
            # `ctypes.CDLL(None)`), which is how a dynamically linked musl
            # process reaches its own libc's crypt().
            handle = if name
                       LibC.dlopen(name.to_unsafe, LibC::RTLD_LAZY)
                     else
                       LibC.dlopen(Pointer(UInt8).null, LibC::RTLD_LAZY)
                     end
            next if handle.null?

            crypt_r = LibC.dlsym(handle, "crypt_r")
            crypt = LibC.dlsym(handle, "crypt")
            next if crypt_r.null? && crypt.null?

            # crypt_r/crypt_gensalt_rn are preferred where present, exactly
            # like ansible's own probes: they write into a caller-supplied
            # buffer, so nothing depends on thread-local static storage.
            unless crypt_r.null?
              @crypt_r = CryptRFn.new(crypt_r, Pointer(Void).null)
            end
            unless crypt.null?
              @crypt_plain = CryptFn.new(crypt, Pointer(Void).null)
            end
            if use_gensalt
              gensalt_rn = LibC.dlsym(handle, "crypt_gensalt_rn")
              gensalt = LibC.dlsym(handle, "crypt_gensalt")
              unless gensalt_rn.null?
                @gensalt_rn = GensaltRnFn.new(gensalt_rn, Pointer(Void).null)
              end
              unless gensalt.null?
                @gensalt_plain = GensaltFn.new(gensalt, Pointer(Void).null)
              end
            end
            return
          end
        end
      end

      # AnsibleError from CryptHash.__init__ when nothing could be loaded.
      NO_CRYPT_MESSAGE = "crypt cannot be used as the 'libxcrypt' library is not installed or is unusable."

      # ansible's `_SALT_CHARS`, used only by the no-gensalt fallback.
      SALT_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./"

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

      # CryptHash.__init__ plus CryptHash.hash(): the crypt library and the
      # algorithm are checked first, then libxcrypt's own crypt_gensalt (with
      # ansible's fallback when only a libc crypt() is available), then crypt().
      def self.hash(secret : String, algorithm : String, salt : String? = nil,
                    salt_size : JSON::Any? = nil, rounds : JSON::Any? = nil,
                    ident : String? = nil) : String
        facade = CryptFacade.facade
        raise NO_CRYPT_MESSAGE unless facade.available?

        algo = ALGORITHMS[algorithm]?
        raise "crypt does not support '#{algorithm}' algorithm" unless algo

        if algo.requires_gensalt && !facade.has_crypt_gensalt?
          raise "'#{algorithm}' algorithm requires libxcrypt"
        end

        rounds_n = rounds_value(rounds) || algo.implicit_rounds
        ident_n = ident && !ident.empty? ? ident : algo.crypt_id
        saltstring = if facade.has_crypt_gensalt?
                       gensalt(algorithm, algo, ident_n, rounds_n, salt, salt_size)
                     else
                       build_saltstring(algorithm, algo, ident_n, rounds_n, salt, salt_size)
                     end

        result = facade.crypt(secret, saltstring)
        raise "crypt does not support '#{algorithm}' algorithm" if result.nil?
        result
      end

      private def self.rounds_value(rounds : JSON::Any?) : Int64?
        return nil if rounds.nil?
        case raw = rounds.raw
        when Nil   then nil
        when Bool  then raw ? 1_i64 : nil
        when Int64 then raw.zero? ? nil : raw
        when Float64
          # crypt_gensalt's count parameter is a C integer: passlib's
          # integer coercion used to accept these, libxcrypt's binding does
          # not (live-verified vs 2.21.6 for both spellings).
          raise "argument 2: TypeError: 'float' object cannot be interpreted as an integer"
        when String
          return nil if raw.empty?
          raise "argument 2: TypeError: 'str' object cannot be interpreted as an integer"
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
        result = CryptFacade.facade.crypt_gensalt(prefix, (rounds || 0).to_u64, rbytes)
        if result.nil?
          # AnsibleError(...) from the ValueError: the displayed text keeps
          # the cause appended (live-verified: an md5_crypt hash asked for
          # rounds reads exactly like this).
          raise "Failed to generate salt for '#{algorithm}' algorithm: crypt_gensalt failed: unable to generate salt"
        end
        result
      end

      # `_build_saltstring`: ansible's own fallback for a crypt library with no
      # crypt_gensalt (musl libc). The salt text is used verbatim - no
      # libxcrypt re-encoding - and the rounds/cost marker is only written when
      # rounds is set.
      private def self.build_saltstring(algorithm : String, algo : Algo, ident : String,
                                        rounds : Int64?, salt : String?,
                                        salt_size : JSON::Any?) : String
        salt_string = if salt.nil? || salt.empty?
                        random_salt(validate_salt_size(algorithm, algo, salt_size))
                      else
                        validate_salt(algorithm, algo, salt, salt_size)
                      end

        saltstring = "$#{ident}"
        if rounds
          if algo.rounds_format == "cost"
            # musl libc requires a 2-digit bcrypt cost ($2b$05$, not $2b$5$).
            saltstring += "$%02d" % rounds
          else
            saltstring += "$rounds=#{rounds}"
          end
        end
        "#{saltstring}$#{salt_string}"
      end

      # ansible's random_salt(): secrets.choice over _SALT_CHARS.
      private def self.random_salt(size : Int32) : String
        String.build(size) do |io|
          size.times { io << SALT_CHARS.byte_at(Random::Secure.rand(SALT_CHARS.bytesize)).unsafe_chr }
        end
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
