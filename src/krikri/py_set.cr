module Krikri
  # Emulation of CPython 3.13's `set` iteration order for INT elements (the
  # order real ansible's `union` / `intersect` / `difference` /
  # `symmetric_difference` filters return, since they are
  # `list(set(a) OP set(b))`). Small-int hashes are deterministic, so the order
  # is reproducible: it is the open-addressing table order of Objects/setobject.c
  # (linear probing of 9 slots, then the perturbed jump, growth x4 at 3/5
  # load). String sets are hash-randomized per real process and cannot be
  # matched - callers must only use this for lists of plain integers.
  class PySet
    LINEAR_PROBES =  9
    PERTURB_SHIFT =  5
    MINSIZE       =  8
    HASH_MOD      = (1_u64 << 61) - 1

    @keys : Array(Int64?)
    @hashes : Array(UInt64)
    @mask : UInt64
    @fill = 0
    @used = 0

    def initialize
      @mask = (MINSIZE - 1).to_u64
      @keys = Array(Int64?).new(MINSIZE, nil)
      @hashes = Array(UInt64).new(MINSIZE, 0_u64)
    end

    protected getter used
    protected getter fill
    protected getter mask
    protected getter keys
    protected getter hashes

    # CPython hash(int): |n| mod (2**61 - 1) with the sign restored, -1 -> -2,
    # reinterpreted as an unsigned 64-bit value.
    def self.py_hash(n : Int64) : UInt64
      negative = n < 0
      magnitude = negative ? (0_u64 &- n.to_u64!) : n.to_u64
      h = magnitude % HASH_MOD
      return (-2_i64).to_u64! if negative && h == 1
      negative ? (0_u64 &- h) : h
    end

    def self.from(list : Array(Int64)) : PySet
      set = PySet.new
      list.each { |k| set.add(k) }
      set
    end

    def add(key : Int64) : Nil
      add_entry(key, PySet.py_hash(key))
    end

    protected def add_entry(key : Int64, hash : UInt64) : Nil
      mask = @mask
      i = hash & mask
      perturb = hash
      loop do
        probes = (i + LINEAR_PROBES <= mask) ? LINEAR_PROBES : 0
        j = i
        (probes + 1).times do
          slot = j.to_i
          existing = @keys[slot]
          if existing.nil?
            @keys[slot] = key
            @hashes[slot] = hash
            @fill += 1
            @used += 1
            resize(@used > 50_000 ? @used * 2 : @used * 4) if @fill * 5 >= mask * 3
            return
          end
          return if @hashes[slot] == hash && existing == key
          j += 1
        end
        perturb >>= PERTURB_SHIFT
        i = (i &* 5 &+ 1 &+ perturb) & mask
      end
    end

    private def resize(minused : Int) : Nil
      newsize = MINSIZE.to_u64
      while newsize <= minused
        newsize <<= 1
      end
      old_keys = @keys
      old_hashes = @hashes
      @mask = newsize - 1
      @keys = Array(Int64?).new(newsize.to_i, nil)
      @hashes = Array(UInt64).new(newsize.to_i, 0_u64)
      old_keys.each_with_index do |key, idx|
        next if key.nil?
        insert_clean(key, old_hashes[idx])
      end
      @fill = @used
    end

    private def insert_clean(key : Int64, hash : UInt64) : Nil
      mask = @mask
      i = hash & mask
      perturb = hash
      loop do
        probes = (i + LINEAR_PROBES <= mask) ? LINEAR_PROBES : 0
        j = i
        (probes + 1).times do
          slot = j.to_i
          if @keys[slot].nil?
            @keys[slot] = key
            @hashes[slot] = hash
            return
          end
          j += 1
        end
        perturb >>= PERTURB_SHIFT
        i = (i &* 5 &+ 1 &+ perturb) & mask
      end
    end

    # setobject.c set_merge: self |= other (used for copies and union).
    protected def merge(other : PySet) : Nil
      if (@fill + other.used) * 5 >= @mask * 3
        resize((@used + other.used) * 2)
      end
      if @fill == 0 && @mask == other.mask
        @keys = other.keys.dup
        @hashes = other.hashes.dup
        @fill = other.fill
        @used = other.used
        return
      end
      if @fill == 0
        other.keys.each_with_index do |key, idx|
          next if key.nil?
          insert_clean(key, other.hashes[idx])
          @fill += 1
          @used += 1
        end
        return
      end
      other.keys.each_with_index do |key, idx|
        next if key.nil?
        add_entry(key, other.hashes[idx])
      end
    end

    def copy : PySet
      result = PySet.new
      result.merge(self)
      result
    end

    def to_a : Array(Int64)
      result = [] of Int64
      @keys.each { |key| result << key if key }
      result
    end

    protected def includes?(key : Int64) : Bool
      @keys.includes?(key)
    end

    # setobject.c set_intersection for set & set: iterate the SMALLER set (b
    # when the sizes are equal) in table order, adding hits to a fresh set.
    # list(set(a) & set(b))
    def self.intersect(a : Array(Int64), b : Array(Int64)) : Array(Int64)
      sa = PySet.from(a)
      sb = PySet.from(b)
      big, small = sb.used > sa.used ? {sb, sa} : {sa, sb}
      result = PySet.new
      small.keys.each_with_index do |key, idx|
        next if key.nil?
        result.add_entry(key, small.hashes[idx]) if big.includes?(key)
      end
      result.to_a
    end

    # setobject.c set_difference: when len(a)>>2 > len(b) it copies a and
    # discards b's members (entries keep their slots); otherwise it iterates a
    # in table order adding the elements not in b to a fresh set.
    # list(set(a) - set(b))
    def self.difference(a : Array(Int64), b : Array(Int64)) : Array(Int64)
      sa = PySet.from(a)
      sb = PySet.from(b)
      if (sa.used >> 2) > sb.used
        result = sa.copy
        result.discard_all(sb)
        return result.to_a
      end
      result = PySet.new
      sa.keys.each_with_index do |key, idx|
        next if key.nil?
        result.add_entry(key, sa.hashes[idx]) unless sb.includes?(key)
      end
      result.to_a
    end

    protected def discard_all(other : PySet) : Nil
      other.keys.each do |key|
        next if key.nil?
        @keys.each_index do |slot|
          if @keys[slot] == key
            @keys[slot] = nil
            break
          end
        end
      end
    end

    # list(set(a) | set(b))
    def self.union(a : Array(Int64), b : Array(Int64)) : Array(Int64)
      result = PySet.from(a).copy
      result.merge(PySet.from(b))
      result.to_a
    end
  end
end
