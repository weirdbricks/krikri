require "yaml"

module Krikri
  module Lint
    # A lint target file with position-aware YAML available.
    # Files that fail to parse carry `parse_error` instead of `root`;
    # the syntax-check rule reports them.
    class PositionedFile
      getter path : String
      getter file_type : FileType
      getter root : YAML::Nodes::Node?
      getter parse_error : ParseErrorInfo?

      struct ParseErrorInfo
        getter line : Int32
        getter column : Int32
        getter message : String

        def initialize(@line, @column, @message)
        end
      end

      def initialize(@path, @file_type, @root, @parse_error)
      end

      def self.load(path : String) : PositionedFile
        source = File.read(path)
        begin
          document = YAML::Nodes.parse(source)
          root = document.nodes.first?
          new(path, FileType.from_path(path), root, nil)
        rescue ex : YAML::ParseException
          info = ParseErrorInfo.new(ex.line_number.to_i, ex.column_number.to_i, ex.message.to_s)
          new(path, FileType.from_path(path), nil, info)
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
        stack = [node]
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
