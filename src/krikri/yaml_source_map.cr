require "yaml"

module Krikri
  # Structural source positions for every node of a YAML document, keyed
  # by a "/"-joined path of mapping keys and sequence indices ("0/tasks/2"
  # = the third task of the first play's `tasks:` section; "4" = the
  # fifth entry of a bare task-file list). The parser's own YAML::Any
  # tree carries no position information (Crystal's YAML::Node has no
  # marks), so the positions come from a second, cheap pass over the raw
  # libyaml event stream - the same parser Crystal's YAML.parse uses, so
  # the structure (and therefore the path correspondence) is identical by
  # construction, and the marks are byte-identical to Ansible's own
  # libyaml-derived Origin positions (0-based mark -> 1-based line/col).
  #
  # Used only to label task-failure error blocks with their playbook
  # origin; a scan failure or a missing path simply yields no position
  # and the block is omitted (never fatal).
  class YamlSourceMap
    alias Pos = Tuple(Int32, Int32)

    # Duplicate mapping keys in document order, as (key, line, column) of
    # the DUPLICATE occurrence's own mark - ansible-core's constructor
    # warns once per occurrence after the first, points the Origin at the
    # repeated key and says "Using last defined value only.", while the
    # last value still wins.
    alias DuplicateKey = Tuple(String, Int32, Int32)

    @positions = Hash(String, Pos).new
    @duplicate_keys = Array(DuplicateKey).new
    @collection_key_pos : Pos? = nil

    getter duplicate_keys

    # The start mark of the mapping holding a collection used AS a mapping
    # key (first occurrence in document order), 1-based line/column -
    # ansible-core 2.19 refuses such a file at load time (rc=4, "This may
    # be an issue with missing quotes around a template block."), because
    # an unquoted ``key: {{ x }}`` parses as a flow mapping whose key is
    # itself a mapping, and Ansible's loader rejects collection keys.
    # krikri's own YAML layer happily builds that structure, so this is
    # the only signal that the file needs the quoting refusal.
    getter collection_key_pos : Pos?

    def self.scan(content : String) : YamlSourceMap
      map = YamlSourceMap.new
      map.scan_events(content)
      map
    end

    def at?(path : String) : Pos?
      @positions[path]?
    end

    # The first (document-order) position whose path ends with *suffix* -
    # for locating a nested var's value inside a file whose top-level
    # wrapping differs by source kind ("0/vars/n/a" in a playbook vs
    # "n/a" in a vars file).
    def suffix_at?(suffix : String) : Pos?
      @positions.each do |path, pos|
        return pos if path.ends_with?(suffix)
      end
      nil
    end

    # The top-level sequence entries as (index, start line) pairs sorted
    # by position - for a playbook these are its plays, letting callers
    # locate which play a given source line belongs to.
    def plays : Array({Int32, Int32})
      entries = @positions.select { |path, _| path.matches?(/\A\d+\z/) }
        .map { |path, pos| {path.to_i, pos[1]} }
      entries.sort_by!(&.[0])
      entries
    end

    private class Container
      property kind : Symbol # :seq or :map
      property index : Int32 # next sequence child index
      property pending_key : String?
      property path : String
      getter seen_keys = Set(String).new

      def initialize(@kind, @path, @index = 0, @pending_key = nil)
      end
    end

    protected def scan_events(content : String) : Nil
      # libyaml's yaml_parser_t is much larger than Crystal's field-mapped
      # LibYAML::Parser struct (which covers only the error/problem fields
      # near its start), so the allocation MUST be LibYAML::PARSER_SIZE -
      # yaml_parser_initialize would otherwise overflow it and corrupt the
      # heap (manifesting later as an infinite libyaml scanner loop or a
      # stray SIGSEGV). Crystal's own YAML::PullParser allocates exactly
      # this way; Pointer(LibYAML::Parser).malloc(1) is the trap.
      parser = Pointer(Void).malloc(LibYAML::PARSER_SIZE).as(LibYAML::Parser*)
      LibYAML.yaml_parser_initialize(parser)
      bytes = content.to_slice
      LibYAML.yaml_parser_set_input_string(parser, bytes, bytes.size)
      event = Pointer(LibYAML::Event).malloc(1)

      stack = [] of Container
      running = true

      # Safety net, not the fix: a malformed event stream must never spin
      # here (positions are best-effort; a truncated scan suppresses the
      # origin labels rather than mislabeling them).
      event_budget = 1_000_000

      while running && event_budget > 0 &&
            LibYAML.yaml_parser_parse(parser, event) == 1
        event_budget -= 1
        case event.value.type
        when .document_start?
          stack.clear
        when .mapping_start?, .sequence_start?
          # A collection arriving while the enclosing mapping has no
          # pending scalar key can only BE that mapping's next key -
          # record the enclosing mapping's own start mark (where its
          # first ``{`` sits) before node_path consumes state. The
          # enclosing mapping's position is already recorded: every
          # container registers itself on entry, the document root at
          # path "".
          note_collection_key(stack)
          enter_collection(stack, event.value.type.mapping_start? ? :map : :seq, event.value.start_mark)
        when .scalar?
          enter_leaf(stack, scalar_text(event), event.value.start_mark)
        when .alias?
          enter_leaf(stack, nil, event.value.start_mark)
        when .mapping_end?, .sequence_end?
          stack.pop?
        when .stream_end?
          running = false
        end
        LibYAML.yaml_event_delete(event)
      end

      LibYAML.yaml_parser_delete(parser)
    rescue
      # A scan failure must never break parsing; positions are optional.
      nil
    end

    private def note_collection_key(stack : Array(Container)) : Nil
      parent = stack.last?
      return unless parent && parent.kind == :map && parent.pending_key.nil?

      @collection_key_pos ||= @positions[parent.path]?
    end

    private def enter_collection(stack : Array(Container), kind : Symbol, mark : LibYAML::Mark) : Nil
      node_path = node_path(stack)
      @positions[node_path] = pos(mark)
      stack << Container.new(kind, node_path)
    end

    private def enter_leaf(stack : Array(Container), text : String?, mark : LibYAML::Mark) : Nil
      parent = stack.last?
      return unless parent

      if parent.kind == :map && parent.pending_key.nil?
        # A scalar mapping KEY: remembered as the pending path component
        # for the value node that follows. Keys themselves get no entry.
        # libyaml hands the keys over in document order, so a repeat here
        # is exactly what ansible-core's construct_mapping warns on (one
        # warning per occurrence after the first, Origin at the repeated
        # key), while the last value still wins.
        if text
          @duplicate_keys << {text, pos(mark)[0], pos(mark)[1]} if parent.seen_keys.includes?(text)
          parent.seen_keys << text
          parent.pending_key = text
        else
          parent.pending_key = "<key#{parent.index += 1}>"
        end
        return
      end

      @positions[node_path(stack)] = pos(mark)
    end

    # Builds the path for the node about to be recorded, consuming the
    # enclosing container's state: a mapping's pending key (or a
    # synthetic component for a collection used AS a key), or a
    # sequence's next index.
    private def node_path(stack : Array(Container)) : String
      parent = stack.last?
      unless parent
        return "" # document root
      end

      component =
        if parent.kind == :map
          if key = parent.pending_key
            parent.pending_key = nil
            key
          else
            parent.index += 1
            "<key#{parent.index}>"
          end
        else
          index = parent.index
          parent.index += 1
          index.to_s
        end

      parent_path = parent.path
      parent_path.empty? ? component : "#{parent_path}/#{component}"
    end

    private def scalar_text(event : LibYAML::Event*) : String?
      scalar = event.value.data.scalar
      return nil unless scalar.value

      String.new(scalar.value, scalar.length)
    end

    private def pos(mark : LibYAML::Mark) : Pos
      {mark.line.to_i32 + 1, mark.column.to_i32 + 1}
    end
  end
end
