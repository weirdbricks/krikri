require "json"
require "big"
require "set"
require "./param_sentinels"

module Krikri
  module FactCache
    # Reader/writer for the on-disk format of Ansible's
    # `community.general.pickle` fact-cache plugin, so a cache directory
    # written by ansible-playbook is reused by krikri and the other way
    # round (issue #1838).
    #
    # The plugin is a thin wrapper over Python's `pickle` module with two
    # properties that make this tractable:
    #
    #   * It writes `pickle.dump(value, protocol=2)` - the pre-frame,
    #     opcode-oriented protocol, not 4/5.
    #   * It declares `_persistent = False`, which makes ansible-core skip
    #     the `s1_<host>` key prefix and the `{"__payload__": "<json>"}`
    #     envelope the jsonfile backend gets. The value it pickles is the
    #     plain per-host fact mapping, and (verified against ansible-core
    #     2.21.6) a 104-fact local gather is 21 distinct opcodes and zero
    #     GLOBAL/REDUCE opcodes.
    #
    # A fact that passed through a templated `set_fact` (with
    # `cacheable: true`) is not a plain string any more: ansible-core
    # 2.21.6 stores it as `_AnsibleTaggedStr` (and the tag bookkeeping as
    # `_AnsibleTagsMapping`/`Origin`/`TrustedAsTemplate` objects), so the
    # reader must also handle `GLOBAL`/`NEWOBJ`/`REDUCE`/`BUILD` and
    # tuples. It accepts those ONLY for the known ansible datatag/unsafe
    # modules, and it never instantiates the named class: the class
    # operand is just a marker, and NEWOBJ/REDUCE unwrap to the plain
    # value they were wrapping. No accepted opcode can therefore import a
    # module or call anything, so the worst an attacker-controlled cache
    # file can do is fail to parse (a cache miss + re-gather). A file that
    # needs anything else - `_codecs encode` for a `bytes` value, a set,
    # an arbitrary class, protocol 4+ framing - is rejected whole
    # (`Pickle::Unsupported`), never partially trusted, and the cache
    # writer leaves such a file untouched instead of clobbering facts it
    # could not read (see FactCache.write).
    #
    # The writer emits protocol 2 as well but skips memoization entirely
    # (facts are acyclic trees), which Python's unpickler accepts: memo
    # entries are an optimization, not a requirement.
    module Pickle
      class Error < Exception
      end

      # A pickle that loads structurally but uses a construct this codec
      # does not model. Distinct from Error so the cache writer can tell
      # "another engine's file in an unsupported shape" (leave it alone)
      # from "garbage" (safe to replace).
      class Unsupported < Error
      end

      # Python's `pickle.load(..., encoding='bytes')` is what the plugin
      # calls; nothing it writes is outside this subset. Public so the
      # cache reader can refuse an oversize file before allocating it.
      MAX_BYTES = 64 * 1024 * 1024
      private MAX_STACK = 1_000_000

      # Bounds the post-load walk that rejects self-referential containers.
      private MAX_DEPTH = 256

      # A memo back-reference can also describe an acyclic DAG that is
      # exponential to walk (nested `{'a': shared, 'b': shared}`), and a
      # memoized tuple can be copied per reference even when the container
      # is later discarded by BUILD. This caps the decode phase's total
      # node visits plus copied tuple elements, which no real fact tree
      # approaches.
      private MAX_NODES = 1_000_000

      # Marker key inside a placeholder mapping that stands in for one of
      # ansible's attribute-only tag objects (`_AnsibleTagsMapping`, the tag
      # classes). Those mappings are keyed by class objects rather than
      # strings and only ever reach ansible's BUILD state, which this decoder
      # discards - but the decoder still has to tolerate building them. A
      # mapping that still carries this key in the final tree means a tag
      # object leaked into the facts, so the file is refused rather than
      # silently stripped (see validate_tree).
      private TAG_PLACEHOLDER_KEY = "\u{E000}pickle:tag"

      # Stack sentinel for MARK. `Nil` is a real value (pickle's None), so
      # the marker cannot be a nilable JSON::Any.
      private struct Mark
      end

      # A whitelisted class object (pickle's GLOBAL). Only ever a marker
      # for NEWOBJ/REDUCE - see unwrap_tag; nothing is ever instantiated.
      private struct TagClass
        getter module_name : String
        getter class_name : String

        def initialize(@module_name : String, @class_name : String)
        end
      end

      # Tuple arguments (NEWOBJ/REDUCE) and tuple values, kept apart from
      # lists so the argument list survives until the opcode consumes it.
      private class PyTuple
        getter items : Array(Item)

        def initialize(@items : Array(Item))
        end
      end

      private alias Item = JSON::Any | Mark | TagClass | PyTuple

      # Decodes a pickle file body into the same tree shape the jsonfile
      # reader returns. Raises Pickle::Error on a truncated stream or a
      # non-mapping root, and Pickle::Unsupported on a construct outside
      # the supported subset.
      def self.decode(bytes : Bytes) : Hash(String, JSON::Any)
        Decoder.new(bytes).decode
      end

      # Serializes *facts* as an ansible-core-compatible pickle file body.
      def self.encode(facts : Hash(String, JSON::Any)) : Bytes
        io = IO::Memory.new(4096)
        io.write_byte(OP_PROTO)
        io.write_byte(2_u8)
        write_value(io, JSON::Any.new(facts))
        io.write_byte(OP_STOP)
        io.to_slice
      end

      # --- opcodes (protocol 0-2 subset ansible-core emits) -------------
      private OP_PROTO        = 0x80_u8
      private OP_FRAME        = 0x95_u8
      private OP_EMPTY_DICT   = 0x7d_u8 # }
      private OP_EMPTY_LIST   = 0x5d_u8 # ]
      private OP_EMPTY_TUPLE  = 0x29_u8 # )
      private OP_MARK         = 0x28_u8 # (
      private OP_TUPLE        = 0x74_u8 # t
      private OP_TUPLE1       = 0x85_u8
      private OP_TUPLE2       = 0x86_u8
      private OP_TUPLE3       = 0x87_u8
      private OP_SETITEM      = 0x73_u8 # s
      private OP_SETITEMS     = 0x75_u8 # u
      private OP_APPEND       = 0x61_u8 # a
      private OP_APPENDS      = 0x65_u8 # e
      private OP_DICT         = 0x64_u8 # d
      private OP_LIST         = 0x6c_u8 # l
      private OP_GLOBAL       = 0x63_u8 # c
      private OP_NEWOBJ       = 0x81_u8
      private OP_REDUCE       = 0x52_u8 # R
      private OP_BUILD        = 0x62_u8 # b
      private OP_BINUNICODE   = 0x58_u8 # X
      private OP_SHORT_BINUNI = 0x8c_u8 # <BINUNICODE> (protocol 4+)
      private OP_BININT       = 0x4a_u8 # J
      private OP_BININT1      = 0x4b_u8 # K
      private OP_BININT2      = 0x4d_u8 # M
      private OP_LONG1        = 0x8a_u8
      private OP_LONG4        = 0x8b_u8
      private OP_BINFLOAT     = 0x47_u8 # G
      private OP_NONE         = 0x4e_u8 # N
      private OP_NEWTRUE      = 0x88_u8
      private OP_NEWFALSE     = 0x89_u8
      private OP_BINPUT       = 0x71_u8 # q
      private OP_LONG_BINPUT  = 0x72_u8 # r
      private OP_BINGET       = 0x68_u8 # h
      private OP_LONG_BINGET  = 0x6a_u8 # j
      private OP_STOP         = 0x2e_u8 # .

      # --- writer --------------------------------------------------------

      private def self.write_value(io : IO, value : JSON::Any) : Nil
        case raw = value.raw
        when Nil
          io.write_byte(OP_NONE)
        when Bool
          io.write_byte(raw ? OP_NEWTRUE : OP_NEWFALSE)
        when Int64
          write_int(io, raw.to_big_i)
        when Float64
          io.write_byte(OP_BINFLOAT)
          io.write_bytes(raw, IO::ByteFormat::BigEndian)
        when String
          if digits = Krikri.bigint_digits(raw)
            write_int(io, BigInt.new(digits))
          else
            bytes = raw.to_slice
            io.write_byte(OP_BINUNICODE)
            io.write_bytes(bytes.size.to_u32, IO::ByteFormat::LittleEndian)
            io.write(bytes)
          end
        when Array
          io.write_byte(OP_EMPTY_LIST)
          unless raw.empty?
            io.write_byte(OP_MARK)
            raw.each { |item| write_value(io, item) }
            io.write_byte(OP_APPENDS)
          end
        when Hash
          io.write_byte(OP_EMPTY_DICT)
          unless raw.empty?
            io.write_byte(OP_MARK)
            raw.each do |key, item|
              write_value(io, JSON::Any.new(key))
              write_value(io, item)
            end
            io.write_byte(OP_SETITEMS)
          end
        else
          raise Error.new("cannot pickle #{raw.class}")
        end
      end

      private def self.write_int(io : IO, value : BigInt) : Nil
        if 0 <= value <= 0xff
          io.write_byte(OP_BININT1)
          io.write_byte(value.to_u8)
        elsif 0 <= value <= 0xffff
          io.write_byte(OP_BININT2)
          io.write_bytes(value.to_u16, IO::ByteFormat::LittleEndian)
        elsif Int32::MIN.to_big_i <= value <= Int32::MAX.to_big_i
          io.write_byte(OP_BININT)
          io.write_bytes(value.to_i32, IO::ByteFormat::LittleEndian)
        else
          bytes = long_bytes(value)
          if bytes.size <= 0xff
            io.write_byte(OP_LONG1)
            io.write_byte(bytes.size.to_u8)
          else
            io.write_byte(OP_LONG4)
            io.write_bytes(bytes.size.to_u32, IO::ByteFormat::LittleEndian)
          end
          io.write(bytes)
        end
      end

      # The fewest little-endian two's-complement bytes that hold *value*,
      # exactly what CPython's `pickle.encode_long` emits (including the
      # sign bit that makes `-128` one byte and `-129` two).
      private def self.long_bytes(value : BigInt) : Bytes
        return Bytes[0_u8] if value == 0

        size = 1
        loop do
          limit = BigInt.new(1) << (8 * size - 1)
          break if -limit <= value < limit
          size += 1
        end

        encoded = value < 0 ? (BigInt.new(1) << (8 * size)) + value : value
        slice = Bytes.new(size)
        size.times do |index|
          slice[index] = (encoded & 0xff).to_u8
          encoded >>= 8
        end
        slice
      end

      # --- reader --------------------------------------------------------

      private class Decoder
        def initialize(bytes : Bytes)
          raise Error.new("pickle stream too large") if bytes.size > MAX_BYTES
          @io = IO::Memory.new(bytes)
          @stack = Array(Item).new
          @memo = Hash(Int32, Item).new
          @work = 0
        end

        # The opcode loop can only raise Pickle::Error / Unsupported: IO
        # EOFs and Int32 overflows from a malformed operand are part of the
        # same contract, not a different failure class for callers to miss.
        def decode : Hash(String, JSON::Any)
          decode_stream
        rescue IO::Error
          raise Error.new("truncated pickle stream")
        rescue OverflowError
          raise Error.new("malformed pickle length")
        end

        private def decode_stream : Hash(String, JSON::Any) # ameba:disable Metrics/CyclomaticComplexity
          # A flat opcode dispatch is the shape of a pickle VM; splitting it
          # would only hide which opcodes are allowed.
          loop do
            op = @io.read_byte
            raise Error.new("truncated pickle stream") unless op

            case op
            when OP_PROTO
              read_byte!("PROTO")
            when OP_FRAME
              @io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
            when OP_EMPTY_DICT
              push(JSON::Any.new(Hash(String, JSON::Any).new))
            when OP_EMPTY_LIST
              push(JSON::Any.new(Array(JSON::Any).new))
            when OP_EMPTY_TUPLE
              push(PyTuple.new([] of Item))
            when OP_MARK
              push(Mark.new)
            when OP_TUPLE
              push(PyTuple.new(pop_to_mark("TUPLE")))
            when OP_TUPLE1
              push(tuple_of(1, "TUPLE1"))
            when OP_TUPLE2
              push(tuple_of(2, "TUPLE2"))
            when OP_TUPLE3
              push(tuple_of(3, "TUPLE3"))
            when OP_GLOBAL
              push(tag_class(read_line("GLOBAL"), read_line("GLOBAL")))
            when OP_NEWOBJ
              push(new_object)
            when OP_REDUCE
              push(reduce)
            when OP_BUILD
              build
            when OP_DICT
              push(JSON::Any.new(build_mapping))
            when OP_LIST
              push(JSON::Any.new(build_list))
            when OP_SETITEM
              set_item
            when OP_SETITEMS
              set_items
            when OP_APPEND
              append
            when OP_APPENDS
              appends
            when OP_BINUNICODE
              push(read_binunicode(4))
            when OP_SHORT_BINUNI
              push(read_binunicode(1))
            when OP_BININT
              push(JSON::Any.new(@io.read_bytes(Int32, IO::ByteFormat::LittleEndian).to_i64))
            when OP_BININT1
              push(JSON::Any.new(read_byte!("BININT1").to_i64))
            when OP_BININT2
              push(JSON::Any.new(@io.read_bytes(UInt16, IO::ByteFormat::LittleEndian).to_i64))
            when OP_LONG1
              push(read_long(1))
            when OP_LONG4
              push(read_long(4))
            when OP_BINFLOAT
              push(JSON::Any.new(@io.read_bytes(Float64, IO::ByteFormat::BigEndian)))
            when OP_NONE
              push(JSON::Any.new(nil))
            when OP_NEWTRUE
              push(JSON::Any.new(true))
            when OP_NEWFALSE
              push(JSON::Any.new(false))
            when OP_BINPUT
              remember(read_byte!("BINPUT").to_i)
            when OP_LONG_BINPUT
              remember(@io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).to_i)
            when OP_BINGET
              recall(read_byte!("BINGET").to_i)
            when OP_LONG_BINGET
              recall(@io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).to_i)
            when OP_STOP
              value = @stack.pop?
              raise Error.new("empty pickle stream") unless value
              raise Error.new("unexpected MARK at end of pickle stream") if value.is_a?(Mark)
              raw = unbox(value, "STOP")
              root = raw.as_h? || raise Error.new("pickle root is not a mapping")
              validate_tree(JSON::Any.new(root), 0, Set(UInt64).new)
              return root
            else
              # Anything else (EXT, PERSID, INST, OBJ, ...) has no
              # meaning for a fact cache; refusing the whole file is the
              # point, not a limitation.
              raise Unsupported.new("unsupported pickle opcode 0x#{op.to_s(16)}")
            end
          end
        end

        # A memo back-reference can describe a self-referential container.
        # Loading it is legal for Python, but every later traversal here
        # (JSON serialization, the pickle writer) would recurse forever, so
        # refuse the file instead of handing the cycle on. Acyclic sharing
        # is accepted, but only within a node budget - see MAX_NODES.
        private def validate_tree(value : JSON::Any, depth : Int32, in_path : Set(UInt64)) : Nil
          charge(1)
          raise Error.new("pickle nesting too deep") if depth > MAX_DEPTH
          case raw = value.raw
          when Hash
            if raw.has_key?(TAG_PLACEHOLDER_KEY)
              raise Unsupported.new("pickle tag object leaked into the facts")
            end
            id = raw.object_id
            raise Error.new("recursive pickle structure") if in_path.includes?(id)
            in_path << id
            raw.each_value { |child| validate_tree(child, depth + 1, in_path) }
            in_path.delete(id)
          when Array
            id = raw.object_id
            raise Error.new("recursive pickle structure") if in_path.includes?(id)
            in_path << id
            raw.each { |child| validate_tree(child, depth + 1, in_path) }
            in_path.delete(id)
          end
        end

        # --- class objects and data-tag unwrapping ----------------------

        # The only `GLOBAL` modules a fact cache may name. ansible-core
        # wraps templated values and their tag bookkeeping in these; the
        # names are only ever compared, never imported or called.
        TAG_MODULES = {
          "ansible.module_utils._internal._datatag",
          "ansible.module_utils._internal._datatag._tags",
          "ansible._internal._datatag._tags",
          "ansible.utils.unsafe_proxy",
        }

        private MAX_GLOBAL_NAME = 256

        private def tag_class(module_name : String, class_name : String) : TagClass
          unless TAG_MODULES.includes?(module_name)
            raise Unsupported.new("unsupported pickle GLOBAL #{module_name}.#{class_name}")
          end
          TagClass.new(module_name, class_name)
        end

        # NEWOBJ/REDUCE over a whitelisted class: unwrap to the value the
        # class wrapped. A single plain argument is the wrapped value
        # (`_AnsibleTaggedStr('x')` is the string `x`); no arguments is an
        # attribute-only tag object (`Origin`, `_AnsibleTagsMapping`),
        # whose payload only ever lives in the BUILD state this decoder
        # discards, so an empty mapping is a faithful placeholder.
        private def unwrap_tag(klass : TagClass, args : Array(Item)) : Item
          if args.size == 1
            value = args[0]
            return value if value.is_a?(JSON::Any)
          elsif args.empty?
            placeholder = Hash(String, JSON::Any).new
            placeholder[TAG_PLACEHOLDER_KEY] = JSON::Any.new(true)
            return JSON::Any.new(placeholder)
          end
          raise Unsupported.new("unsupported #{klass.module_name}.#{klass.class_name} payload")
        end

        private def new_object : Item
          args = pop_tuple("NEWOBJ")
          klass = pop_class("NEWOBJ")
          unwrap_tag(klass, args)
        end

        private def reduce : Item
          args = pop_tuple("REDUCE")
          klass = pop_class("REDUCE")
          unwrap_tag(klass, args)
        end

        # BUILD sets instance attributes from a state object. Nothing here
        # has attributes worth keeping (tag metadata only), so the object
        # is kept and the state dropped.
        private def build : Nil
          state = @stack.pop?
          raise Error.new("pickle stream underflow in BUILD") unless state
          object = @stack.pop?
          raise Error.new("pickle stream underflow in BUILD") unless object
          raise Error.new("unexpected MARK in BUILD") if object.is_a?(Mark)
          @stack << object
        end

        private def pop_tuple(context : String) : Array(Item)
          item = @stack.pop?
          raise Error.new("pickle stream underflow in #{context}") unless item
          raise Error.new("MARK in #{context}") if item.is_a?(Mark)
          item.is_a?(PyTuple) ? item.items : raise Error.new("#{context} argument is not a tuple")
        end

        private def pop_class(context : String) : TagClass
          item = @stack.pop?
          raise Error.new("pickle stream underflow in #{context}") unless item
          item.is_a?(TagClass) ? item : raise Unsupported.new("#{context} callable is not a whitelisted class")
        end

        private def tuple_of(count : Int32, context : String) : PyTuple
          items = Array(Item).new(count)
          count.times { items.unshift(pop_item(context)) }
          PyTuple.new(items)
        end

        private def read_line(context : String) : String
          bytes = [] of UInt8
          loop do
            byte = @io.read_byte || raise Error.new("truncated #{context}")
            break if byte == 0x0a
            raise Unsupported.new("oversized #{context} name") if bytes.size >= MAX_GLOBAL_NAME
            bytes << byte
          end
          slice = Bytes.new(bytes.size)
          bytes.each_with_index { |byte, index| slice[index] = byte }
          String.new(slice)
        end

        # --- stack helpers ----------------------------------------------

        private def read_byte!(context : String) : UInt8
          @io.read_byte || raise Error.new("truncated pickle stream (#{context})")
        end

        private def push(item : Item) : Nil
          raise Error.new("pickle stack overflow") if @stack.size >= MAX_STACK
          @stack << item
        end

        private def pop_item(context : String) : Item
          item = @stack.pop?
          raise Error.new("pickle stream underflow in #{context}") unless item
          raise Error.new("unexpected MARK in #{context}") if item.is_a?(Mark)
          item
        end

        private def pop_value(context : String) : JSON::Any
          unbox(pop_item(context), context)
        end

        private def top_value(context : String) : JSON::Any
          item = @stack.last?
          raise Error.new("pickle stream underflow in #{context}") unless item
          raise Error.new("unexpected MARK in #{context}") if item.is_a?(Mark)
          unbox(item, context)
        end

        # A value position: tuples flatten to arrays (JSON has no tuple
        # type, and jsonfile-cached facts are lists anyway).
        private def unbox(item : Item, context : String) : JSON::Any
          case item
          when JSON::Any
            item
          when PyTuple
            # Every tuple-to-array conversion copies its elements, and a
            # memo lets a stream ask for that copy repeatedly (and then
            # BUILD away the container), so the copy is what the budget
            # has to cover - not just the surviving tree.
            charge(item.items.size)
            values = Array(JSON::Any).new(item.items.size)
            item.items.each do |child|
              raise Unsupported.new("non-value tuple element in #{context}") unless child.is_a?(JSON::Any)
              values << child
            end
            JSON::Any.new(values)
          when TagClass
            raise Unsupported.new("bare class object in #{context}")
          else
            raise Error.new("unexpected MARK in #{context}")
          end
        end

        private def charge(count : Int32) : Nil
          @work += count
          raise Unsupported.new("pickle graph too large") if @work > MAX_NODES
        end

        private def pop_to_mark(context : String) : Array(Item)
          items = Array(Item).new
          loop do
            item = @stack.pop?
            raise Error.new("missing MARK in #{context}") unless item
            break if item.is_a?(Mark)
            items << item
          end
          items.reverse!
        end

        private def build_mapping : Hash(String, JSON::Any)
          items = pop_to_mark("DICT")
          raise Error.new("odd number of DICT items") unless items.size.even?
          mapping = Hash(String, JSON::Any).new
          index = 0
          while index < items.size
            mapping[string_key(unbox(items[index], "DICT"), "DICT")] = unbox(items[index + 1], "DICT")
            index += 2
          end
          mapping
        end

        # Pickle mappings can hold any hashable key; facts only ever use
        # strings, so anything else means this is not a fact cache file.
        private def string_key(value : JSON::Any, context : String) : String
          value.as_s? || raise Error.new("non-string key in #{context}")
        end

        private def build_list : Array(JSON::Any)
          pop_to_mark("LIST").map { |item| unbox(item, "LIST") }
        end

        private def set_item : Nil
          value = pop_item("SETITEM")
          key = pop_item("SETITEM")
          target = mapping_of("SETITEM")
          if target.has_key?(TAG_PLACEHOLDER_KEY)
            # ansible's tag bookkeeping: arbitrary keys (class objects),
            # no fact data - keep only plain string/JSON entries.
            if key.is_a?(JSON::Any) && (name = key.as_s?) && value.is_a?(JSON::Any)
              target[name] = value
            end
          else
            target[string_key(unbox(key, "SETITEM"), "SETITEM")] = unbox(value, "SETITEM")
          end
        end

        private def set_items : Nil
          items = pop_to_mark("SETITEMS")
          raise Error.new("odd number of SETITEMS items") unless items.size.even?
          mapping = mapping_of("SETITEMS")
          tolerant = mapping.has_key?(TAG_PLACEHOLDER_KEY)
          index = 0
          while index < items.size
            key_item = items[index]
            value_item = items[index + 1]
            if tolerant
              if key_item.is_a?(JSON::Any) && (name = key_item.as_s?) && value_item.is_a?(JSON::Any)
                mapping[name] = value_item
              end
            else
              mapping[string_key(unbox(key_item, "SETITEMS"), "SETITEMS")] = unbox(value_item, "SETITEMS")
            end
            index += 2
          end
        end

        private def append : Nil
          value = pop_value("APPEND")
          list_of("APPEND") << value
        end

        private def appends : Nil
          items = pop_to_mark("APPENDS")
          list = list_of("APPENDS")
          items.each { |item| list << unbox(item, "APPENDS") }
        end

        private def mapping_of(context : String) : Hash(String, JSON::Any)
          top_value(context).as_h? || raise Error.new("#{context} target is not a mapping")
        end

        private def list_of(context : String) : Array(JSON::Any)
          top_value(context).as_a? || raise Error.new("#{context} target is not a list")
        end

        private def remember(index : Int32) : Nil
          raise Error.new("negative pickle memo index") if index < 0
          item = @stack.last?
          raise Error.new("pickle stream underflow in BINPUT") unless item
          raise Error.new("unexpected MARK in BINPUT") if item.is_a?(Mark)
          @memo[index] = item
        end

        private def recall(index : Int32) : Nil
          value = @memo[index]?
          raise Error.new("unknown pickle memo index #{index}") unless value
          push(value)
        end

        private def read_binunicode(length_bytes : Int32) : JSON::Any
          size =
            if length_bytes == 4
              @io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).to_i
            else
              (@io.read_byte || raise Error.new("truncated BINUNICODE length")).to_i
            end
          # A claimed length past the end of the stream must not become an
          # allocation: a 30-byte file can claim 2 GiB.
          raise Error.new("BINUNICODE length exceeds stream size") if size > @io.size - @io.pos
          bytes = Bytes.new(size)
          @io.read_fully(bytes)
          string = String.new(bytes)
          raise Error.new("invalid UTF-8 in BINUNICODE") unless string.valid_encoding?
          JSON::Any.new(string)
        end

        private def read_long(length_bytes : Int32) : JSON::Any
          size = 0_u32
          length_bytes.times do |index|
            size |= read_byte!("LONG").to_u32 << (8 * index)
          end
          length = size.to_i
          raise Error.new("LONG length exceeds stream size") if length.to_i64 > @io.size - @io.pos
          bytes = Bytes.new(length)
          @io.read_fully(bytes)
          value = 0.to_big_i
          bytes.each_with_index { |byte, index| value |= byte.to_big_i << (8 * index) }
          value -= 1.to_big_i << (8 * length) if length > 0 && (bytes[length - 1] & 0x80) != 0
          # Anything that fits Int64 is a plain integer, however many
          # bytes another writer chose to spend on it.
          if Int64::MIN.to_big_i <= value <= Int64::MAX.to_big_i
            JSON::Any.new(value.to_i64)
          else
            # JSON::Any tops out at Int64; wide values ride the same
            # sentinel-string convention Krikri::BigJson uses.
            JSON::Any.new(Krikri.bigint_sentinel(value.to_s))
          end
        end
      end
    end
  end
end
