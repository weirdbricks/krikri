require "yaml"

module Krikri
  module Lint
    # A lint target file with position-aware YAML available.
    # Files that fail to parse carry `parse_error` instead of `root`;
    # the load-failure rule reports them.
    class PositionedFile
      getter path : String
      getter file_type : FileType
      getter root : YAML::Nodes::Node?
      getter parse_error : ParseErrorInfo?
      # Whether this file was a lintable of the run itself (a target, or a
      # file found by walking a target directory) rather than a child the
      # run reached through a play's imports or roles. Upstream parses an
      # explicit lintable before any rule runs but parses a child lazily
      # inside the first rule's matchlines walk, which shows up in a
      # warning[outdated-tag] match's line (see OutdatedTagRule).
      property? explicit : Bool = true

      struct ParseErrorInfo
        getter line : Int32
        getter column : Int32
        getter message : String

        def initialize(@line, @column, @message)
        end
      end

      def initialize(@path, @file_type, @root, @parse_error)
      end

      # Upstream's base kind, which decides whether the yaml/task rules
      # dispatch at all: assigned from the file name alone, independently
      # of the explicit kind a `kinds:` pattern gives the file. A custom
      # kind on a non-yaml file therefore runs no yaml rules upstream.
      def base_yaml? : Bool
        FileType.text_yaml_name?(@path)
      end

      def self.load(path : String, kinds : Array(KindPattern) = [] of KindPattern) : PositionedFile
        type = FileType.from_path(path, kinds)
        source = File.read(path)
        # A sanity ignore file is plain text, which upstream never loads
        # as YAML: parsing it here would report a load-failure for a file
        # the sanity rule alone answers for.
        return new(path, type, nil, nil) if type.sanity_ignore?
        begin
          document = YAML::Nodes.parse(source)
          root = document.nodes.first?
          new(path, type, root, nil)
        rescue ex : YAML::ParseException
          info = ParseErrorInfo.new(ex.line_number.to_i, ex.column_number.to_i, ex.message.to_s)
          new(path, type, nil, info)
        end
      end
    end

    module NodeUtil
      extend self

      # 1-based line/column, falling back to 1 for nodes without position
      # data (should not happen with YAML::Nodes.parse output).
      def line(node : YAML::Nodes::Node?) : Int32
        n = node || return 1
        n.start_line > 0 ? n.start_line : 1
      end

      def column(node : YAML::Nodes::Node?) : Int32
        n = node || return 1
        n.start_column > 0 ? n.start_column : 1
      end

      def scalar?(node : YAML::Nodes::Node?) : Bool
        node.is_a?(YAML::Nodes::Scalar)
      end

      def scalar_value(node : YAML::Nodes::Node) : String?
        node.as?(YAML::Nodes::Scalar).try(&.value)
      end

      # PyYAML's YAML 1.1 implicit resolvers, as far as they decide the
      # Python type an unquoted scalar loads as. Ansible sees the loaded
      # objects, not the text, so rules that care about a value being a
      # str have to resolve these the same way.
      PY_NULL_SCALARS = Set{"", "~", "null", "Null", "NULL"}
      PY_BOOL_SCALARS = Set{
        "yes", "Yes", "YES", "no", "No", "NO",
        "true", "True", "TRUE", "false", "False", "FALSE",
        "on", "On", "ON", "off", "Off", "OFF",
      }
      PY_INT_SCALAR   = /\A(?:[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)\z/
      PY_FLOAT_SCALAR = /\A(?:[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?|\.[0-9_]+(?:[eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z/
      # Tags whose constructed value is not a Python str (binary gives
      # bytes, timestamp a date). str, !vault and !unsafe all construct
      # str subclasses, so those stay strings.
      PY_NON_STR_TAGS = Set{
        "tag:yaml.org,2002:null", "tag:yaml.org,2002:bool",
        "tag:yaml.org,2002:int", "tag:yaml.org,2002:float",
        "tag:yaml.org,2002:binary", "tag:yaml.org,2002:timestamp",
      }
      PY_STR_TAGS = Set{
        "tag:yaml.org,2002:str", "!vault", "!unsafe",
      }

      # Whether the loader hands Python a str for this node. A mapping, a
      # sequence, null, a bool or a number all are not strings; quoted
      # and otherwise unresolved plain scalars are.
      def python_str?(node : YAML::Nodes::Node) : Bool
        scalar = node.as?(YAML::Nodes::Scalar) || return false
        if tag = scalar.tag
          return false if PY_NON_STR_TAGS.includes?(tag)
          return true if PY_STR_TAGS.includes?(tag)
        end
        return true unless scalar.style.plain?
        value = scalar.value
        return false if PY_NULL_SCALARS.includes?(value)
        return false if PY_BOOL_SCALARS.includes?(value)
        !value.matches?(PY_INT_SCALAR) && !value.matches?(PY_FLOAT_SCALAR)
      end

      # Iterate a mapping's flat [k1, v1, k2, v2, ...] node list as pairs.
      def each_entry(mapping : YAML::Nodes::Mapping, &)
        nodes = mapping.nodes
        i = 0
        while i + 1 < nodes.size
          yield nodes[i], nodes[i + 1]
          i += 2
        end
      end

      # Find a mapping entry by key name; yields the key and value nodes.
      def entry(mapping : YAML::Nodes::Mapping, key : String) : {YAML::Nodes::Node, YAML::Nodes::Node}?
        found = nil
        each_entry(mapping) do |k, v|
          if found.nil? && (kv = k.as?(YAML::Nodes::Scalar)) && kv.value == key
            found = {k, v}
          end
        end
        found
      end

      # Depth-first walk of every node in the tree (iterative; a
      # recursive yield-based implementation hits Crystal's recursive
      # block-inlining limit).
      def walk(node : YAML::Nodes::Node, &) : Nil
        stack = [] of YAML::Nodes::Node
        stack << node
        while current = stack.pop?
          yield current
          case current
          when YAML::Nodes::Document
            current.nodes.each { |child| stack << child }
          when YAML::Nodes::Mapping
            current.nodes.each { |child| stack << child }
          when YAML::Nodes::Sequence
            current.nodes.each { |child| stack << child }
          end
        end
      end
    end
  end
end
