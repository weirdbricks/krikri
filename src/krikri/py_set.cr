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
    # setobject.c stores a deleted entry as key=<dummy>, hash=-1; no integer
    # hash can collide with it (int hashes are |n| mod 2**61-1, so they never
    # reach 2**64-1), which makes this a safe marker for a tombstone slot.
    DUMMY_HASH    =  ~0_u64

    @keys : Array(Int64?)
    @hashes : Array(UInt64)
    @dummies : Array(Bool)
    @mask : UInt64
    @fill = 0
    @used = 0

    def initialize
      @mask = (MINSIZE - 1).to_u64
      @keys = Array(Int64?).new(MINSIZE, nil)
      @hashes = Array(UInt64).new(MINSIZE, 0_u64)
      @dummies = Array(Bool).new(MINSIZE, false)
    end

    protected getter used
    protected getter fill
    protected getter mask
    protected getter keys
    protected getter hashes
    protected getter dummies

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

    # setobject.c set_add_entry: an unused slot terminates the probe, a
    # DUMMY slot does not (probing must step over it) but is remembered as
    # `freeslot` so a new key reuses it instead of growing `fill`. Reusing a
    # dummy bumps `used` only - no resize check, exactly as CPython does.
    protected def add_entry(key : Int64, hash : UInt64) : Nil
      mask = @mask
      i = hash & mask
      freeslot = -1
      perturb = hash
      loop do
        probes = (i + LINEAR_PROBES <= mask) ? LINEAR_PROBES : 0
        j = i
        (probes + 1).times do
          slot = j.to_i
          if @keys[slot].nil?
            if freeslot < 0
              @keys[slot] = key
              @hashes[slot] = hash
              @fill += 1
              @used += 1
              resize(@used > 50_000 ? @used * 2 : @used * 4) if @fill * 5 >= mask * 3
            else
              @keys[freeslot] = key
              @hashes[freeslot] = hash
              @dummies[freeslot] = false
              @used += 1
            end
            return
          end
          return if @hashes[slot] == hash && @keys[slot] == key
          freeslot = slot if @dummies[slot]
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
      old_dummies = @dummies
      @mask = newsize - 1
      @keys = Array(Int64?).new(newsize.to_i, nil)
      @hashes = Array(UInt64).new(newsize.to_i, 0_u64)
      @dummies = Array(Bool).new(newsize.to_i, false)
      old_keys.each_with_index do |key, idx|
        next if key.nil? || old_dummies[idx]
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
      if @fill == 0 && @mask == other.mask && other.fill == other.used
        @keys = other.keys.dup
        @hashes = other.hashes.dup
        @dummies = other.dummies.dup
        @fill = other.fill
        @used = other.used
        return
      end
      if @fill == 0
        other.keys.each_with_index do |key, idx|
          next if key.nil? || other.dummies[idx]
          insert_clean(key, other.hashes[idx])
          @fill += 1
          @used += 1
        end
        return
      end
      other.keys.each_with_index do |key, idx|
        next if key.nil? || other.dummies[idx]
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
      @keys.each_with_index do |key, idx|
        result << key if key && !@dummies[idx]
      end
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
          next if @dummies[slot]
          if @keys[slot] == key
            @keys[slot] = nil
            break
          end
        end
      end
    end

    # setobject.c set_lookkey: the probe returns the slot holding the key, or
    # the unused slot it stopped at ({slot, false}).
    private def lookkey(key : Int64, hash : UInt64) : {Int32, Bool}
      mask = @mask
      i = hash & mask
      perturb = hash
      loop do
        probes = (i + LINEAR_PROBES <= mask) ? LINEAR_PROBES : 0
        j = i
        (probes + 1).times do
          slot = j.to_i
          return {slot.to_i32, false} if @keys[slot].nil?
          return {slot.to_i32, true} if @hashes[slot] == hash && @keys[slot] == key
          j += 1
        end
        perturb >>= PERTURB_SHIFT
        i = (i &* 5 &+ 1 &+ perturb) & mask
      end
    end

    # setobject.c set_discard_entry: tombstone the slot (still occupied for
    # probing, skipped by iteration) and decrement `used` - `fill` is NOT
    # decremented. Returns false when the key was absent (DISCARD_NOTFOUND).
    protected def discard_entry(key : Int64) : Bool
      slot, found = lookkey(key, PySet.py_hash(key))
      return false unless found
      @dummies[slot] = true
      @hashes[slot] = DUMMY_HASH
      @used -= 1
      true
    end

    # setobject.c set_symmetric_difference for `set(a) ^ set(b)`: the result
    # starts as a copy of set(b), then every entry of set(a) - in set(a)'s
    # own table order - is either tombstoned in the result (when it is also a
    # member of b) or added to it. That leaves the result's iteration order
    # shaped by where the tombstones and the fresh inserts landed, which is
    # why this cannot be derived from the other three operations.
    # list(set(a) ^ set(b))
    def self.symmetric_difference(a : Array(Int64), b : Array(Int64)) : Array(Int64)
      sa = PySet.from(a)
      result = PySet.from(b).copy
      sa.keys.each_with_index do |key, idx|
        next if key.nil?
        result.add_entry(key, sa.hashes[idx]) unless result.discard_entry(key)
      end
      result.to_a
    end

    # list(set(a) | set(b))
    def self.union(a : Array(Int64), b : Array(Int64)) : Array(Int64)
      result = PySet.from(a).copy
      result.merge(PySet.from(b))
      result.to_a
    end
  end
end
