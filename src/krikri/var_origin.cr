require "./yaml_source_map"

module Krikri
  # Where a variable's stored (raw) value was defined - the locator real
  # ansible-core 2.19 prints in a `[WARNING]: Encountered N template error(s).`
  # block when a task NAME's template chain fails inside that value
  # (live-verified 2.19.11: the Origin points at the DEFINING site of the
  # failing value, e.g. `vars/main.yml:3:12` for a role var, not at the
  # task). Three shapes exist, because Ansible's Origin covers values that
  # did not all come from a YAML file:
  #
  # - a YAML-defined value: `Origin: <file>:<line>:<col>` with the usual
  #   2-context-line excerpt and a caret under the value token's first
  #   character (quote included);
  # - an inventory-line value: `Origin: <file>:<line>` - NO column - with
  #   the same excerpt but a full-line caret RUN under the whole line;
  # - a CLI extra var: `Origin: <CLI option '-e'>` with the raw value
  #   excerpted verbatim and no line numbers or caret at all.
  abstract class VarOrigin
    # Grouping key for the consecutive same-origin run a context exit
    # collapses into one warning block (live-verified: two errors from one
    # defining file share a block, an intervening error from another file
    # splits it).
    abstract def group_key : String

    # Top-level `key: value` origins of a vars-style YAML file (a role's
    # vars/main.yml or defaults/main.yml, a vars_files entry): the VALUE
    # scalar's own start mark - Ansible's Origin for the value points at the
    # value token's first character, quote included (live-verified 2.19.11:
    # `nats_name: "{{ ... }}"` reports column 12, the opening quote).
    # *keys* are the file's top-level variable names as the caller parsed
    # them; a key the source-map scan cannot locate simply gets no origin
    # (the warning block for it is then omitted, never mislabeled).
    def self.vars_file_origins(path : String, keys : Enumerable(String)) : Hash(String, VarOrigin)
      origins = Hash(String, VarOrigin).new
      return origins unless File.file?(path)

      map = YamlSourceMap.scan(File.read(path))
      keys.each do |key|
        next unless (pos = map.at?(key))
        origins[key] = FileVarOrigin.new(File.expand_path(path), pos[0], pos[1])
      end
      origins
    end
  end

  # A value defined in a file at a known position. *column* 0 means the
  # position has no column (inventory lines) and renders line-only.
  class FileVarOrigin < VarOrigin
    getter path : String
    getter line : Int32
    getter column : Int32

    def initialize(@path : String, @line : Int32, @column : Int32)
    end

    def group_key : String
      "#{path}:#{line}:#{column}"
    end
  end

  # A value handed to ansible-playbook on the command line.
  class TextVarOrigin < VarOrigin
    getter label : String
    getter text : String

    def initialize(@label : String, @text : String)
    end

    def group_key : String
      "#{label}\u0000#{text}"
    end
  end
end
