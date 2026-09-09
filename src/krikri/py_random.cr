# Bit-exact reimplementation of CPython's `random.Random` as needed by the
# Jinja2 `random` filter (`{{ N | random(seed=inventory_hostname) }}`,
# `{{ list | random(seed=...) }}`), so the SAME seed string produces the
# SAME value real ansible-playbook would on the target host - the whole
# point of a seeded random is cross-run (and cross-engine) stability, e.g.
# lean_delivery.jenkins_slave's password generation picking a uid less than
# 65534 deterministically per inventory host.
#
# Matches CPython's Lib/random.py + Modules/_randommodule.c exactly:
#   - str/bytes seeds are utf-8 encoded, hashed with SHA-512 (64-byte
#     digest appended), and converted to a big-endian int (Lib/random.py
#     `seed()` version=2 path), whose 32-bit words feed `init_by_array`
#     little-endian (lowest word first), exactly as _randommodule.c's
#     `random_seed` does.
#   - integer seeds feed `init_by_array` directly (little-endian words).
#   - Mersenne Twister 19937 core (init_genrand(19650218) + init_by_array
#     + genrand_uint32), the same state machine CPython uses.
#   - `randrange(n)` is Lib/random.py's `_randbelow_with_getrandbits`:
#     k = n.bit_length(), r = getrandbits(k), retry while r >= n.
#   - `getrandbits(k)` matches _randommodule.c's word assembly (words
#     little-endian, last word shifted right when k % 32 != 0).
#   - `choice(seq)` matches Python 3.11+'s `seq[self._randbelow(len(seq))]`
#     (pre-3.11 used `int(random() * len(seq))` instead - a host still
#     running Python 3.10 would get different values for the LIST form;
#     the int/randrange form is identical across all versions).
require "digest"

module Krikri
  class PyRandom
    N          =            624
    M          =            397
    MATRIX_A   = 0x9908b0df_u32
    UPPER_MASK = 0x80000000_u32
    LOWER_MASK = 0x7fffffff_u32

    @mt : Array(UInt32) = Array(UInt32).new(N, 0_u32)
    @index : Int32 = N

    def initialize(seed : String | Int)
      key = seed.is_a?(String) ? self.class.seed_key_words(seed) : self.class.int_key_words(seed.to_i64)
      init_by_array(key)
    end

    # Lib/random.py seed(): a str seed becomes
    # `int.from_bytes(seed.encode() + sha512(seed.encode()).digest(), 'big')`.
    # The digest is appended to the utf-8 bytes, then the whole payload is
    # one big-endian integer.
    def self.seed_key_words(seed : String) : Array(UInt32)
      payload = seed.encode("UTF-8")
      payload = payload + Digest::SHA512.digest(payload)
      bytes_key_words(payload)
    end

    # An int seed is used as-is; its 32-bit words go into init_by_array
    # lowest first (little-endian), leading zero words dropped.
    def self.int_key_words(seed : Int64) : Array(UInt32)
      return [0_u32] if seed == 0
      words = [] of UInt32
      value = seed.to_u64
      while value > 0
        words << (value & 0xffffffff).to_u32!
        value >>= 32
      end
      words
    end

    # Splits a big-endian byte payload into 32-bit words, lowest word
    # first (the layout `_PyLong_AsByteArray` produces for the integer
    # `int.from_bytes(payload, 'big')`), trimming leading zero words the
    # way `_PyLong_NumBits`-derived `keyused` does. Byte indices past the
    # start of the payload contribute zero.
    def self.bytes_key_words(payload : Bytes) : Array(UInt32)
      length = payload.size
      all_words = [] of UInt32
      word_index = 0
      while 4 * word_index < length
        word = 0_u32
        4.times do |j|
          idx = length - 4 * (word_index + 1) + j
          byte = idx >= 0 ? payload[idx].to_u32 : 0_u32
          word = (word << 8) | byte
        end
        all_words << word
        word_index += 1
      end
      until all_words.size <= 1 || all_words.last != 0
        all_words.pop
      end
      all_words
    end

    private def init_genrand(s : UInt32) : Nil
      @mt = Array(UInt32).new(N, 0_u32)
      @mt[0] = s
      (1...N).each do |i|
        prev = @mt[i - 1]
        @mt[i] = (1812433253_u32 &* (prev ^ (prev >> 30)) &+ i.to_u32) & 0xffffffff_u32
      end
      @index = N
    end

    private def init_by_array(key : Array(UInt32)) : Nil
      init_genrand(19650218_u32)
      i = 1
      j = 0
      k = Math.max(N, key.size)
      while k > 0
        prev = @mt[i - 1]
        @mt[i] = ((@mt[i] ^ ((prev ^ (prev >> 30)) &* 1664525_u32)) &+ key[j] &+ j.to_u32) & 0xffffffff_u32
        i += 1
        j += 1
        if i >= N
          @mt[0] = @mt[N - 1]
          i = 1
        end
        j = 0 if j >= key.size
        k -= 1
      end
      k = N - 1
      while k > 0
        prev = @mt[i - 1]
        @mt[i] = ((@mt[i] ^ ((prev ^ (prev >> 30)) &* 1566083941_u32)) &- i.to_u32) & 0xffffffff_u32
        i += 1
        if i >= N
          @mt[0] = @mt[N - 1]
          i = 1
        end
        k -= 1
      end
      @mt[0] = 0x80000000_u32
      @index = N
    end

    private def twist! : Nil
      (0...N - M).each do |state_index|
        y = (@mt[state_index] & UPPER_MASK) | (@mt[state_index + 1] & LOWER_MASK)
        @mt[state_index] = @mt[state_index + M] ^ (y >> 1) ^ (y.odd? ? MATRIX_A : 0_u32)
      end
      (N - M...N - 1).each do |state_index|
        y = (@mt[state_index] & UPPER_MASK) | (@mt[state_index + 1] & LOWER_MASK)
        @mt[state_index] = @mt[state_index + (M - N)] ^ (y >> 1) ^ (y.odd? ? MATRIX_A : 0_u32)
      end
      y = (@mt[N - 1] & UPPER_MASK) | (@mt[0] & LOWER_MASK)
      @mt[N - 1] = @mt[M - 1] ^ (y >> 1) ^ (y.odd? ? MATRIX_A : 0_u32)
      @index = 0
    end

    private def genrand_u32 : UInt32
      twist! if @index >= N
      y = @mt[@index]
      @index += 1
      y ^= y >> 11
      y ^= (y << 7) & 0x9d2c5680_u32
      y ^= (y << 15) & 0xefc60000_u32
      y ^= y >> 18
      y
    end

    # _randommodule.c's getrandbits: `words = (k - 1) / 32 + 1` words
    # assembled little-endian, with the final word's low bits dropped
    # (`r >>= (32 - k)`) when the bit count isn't a multiple of 32.
    # Supports up to 64 bits, far beyond any randrange/choice use here.
    def getrandbits(k : Int) : Int64
      raise ArgumentError.new("getrandbits supports 1..64 bits") unless k >= 1 && k <= 64
      words = (k - 1) // 32 + 1
      result = 0_i64
      bits = k
      words.times do |i|
        r = genrand_u32
        r = r >> (32 - bits) if bits < 32
        result |= r.to_i64 << (32 * i)
        bits -= 32
      end
      result
    end

    # Lib/random.py `_randbelow_with_getrandbits`.
    def randbelow(n : Int) : Int64
      return 0_i64 if n <= 0
      k = n.to_u64.bit_length
      loop do
        r = getrandbits(k)
        return r if r < n
      end
    end

    # random.Random.randrange(stop) for the one-argument form: the width
    # itself is the exclusive upper bound.
    def randrange(stop : Int) : Int64
      randbelow(stop)
    end

    # random.Random.choice(seq) - Python 3.11+ form (index via _randbelow).
    def choice(list : Array(V)) : V forall V
      raise ArgumentError.new("Cannot choose from an empty sequence") if list.empty?
      list[randbelow(list.size)]
    end
  end
end
