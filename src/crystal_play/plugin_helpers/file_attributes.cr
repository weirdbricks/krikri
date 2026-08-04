module CrystalPlay
  module PluginHelpers
    # FileAttributes - pure parsing for stat's get_mime/get_attributes
    # options. Both shell out in real Ansible too (`file` and `lsattr`
    # have no native Crystal or stdlib equivalent - this mirrors real
    # Ansible's own module_utils/basic.py exactly, not a missed
    # native-conversion opportunity like stat/find's old shell versions
    # were), so this module only covers parsing their output, not running
    # the commands themselves (that's the plugin's own job, via the
    # existing local/remote `remote_exec` split).
    module FileAttributes
      # Maps lsattr's single-letter flags to their real Ansible attribute
      # names - verified against a real ansible-core install's own
      # module_utils/common/file.py FILE_ATTRIBUTES table, not guessed.
      FLAG_NAMES = {
        'A' => "noatime", 'a' => "append", 'c' => "compressed", 'C' => "nocow",
        'd' => "nodump", 'D' => "dirsync", 'e' => "extents", 'E' => "encrypted",
        'h' => "blocksize", 'i' => "immutable", 'I' => "indexed", 'j' => "journalled",
        'N' => "inline", 's' => "zero", 'S' => "synchronous", 't' => "notail",
        'T' => "blockroot", 'u' => "undelete", 'X' => "compressedraw", 'Z' => "compresseddirty",
      }

      # Parses `file --mime-type --mime-encoding <path>`'s output, shaped
      # like "path: text/plain; charset=us-ascii". Returns {"unknown",
      # "unknown"} (real Ansible's own fallback value, not a Crystal
      # invention) if the output doesn't match that shape.
      def self.parse_mime(output : String) : {String, String}
        # rsplit(":", 1) in the real module, to tolerate a colon inside
        # the path itself - only the *last* colon separates the path from
        # the mimetype/charset pair.
        _, _, rest = output.strip.rpartition(':')
        mimetype, _, charset_part = rest.partition(';')
        return {"unknown", "unknown"} if mimetype.empty? || charset_part.empty?

        _, _, charset = charset_part.partition('=')
        return {"unknown", "unknown"} if charset.empty?

        {mimetype.strip, charset.strip}
      end

      # Parses `lsattr -vd <path>`'s output, shaped like
      # "719511458  --------------e------- /path" (version, dash-padded
      # flags, path - whitespace-separated). Returns {nil, "", [] of
      # String} (real Ansible's own fallback, e.g. on a filesystem lsattr
      # doesn't support) if the output doesn't match that shape.
      def self.parse_lsattr(output : String) : {String?, String, Array(String)}
        fields = output.strip.split
        return {nil, "", [] of String} if fields.size < 2

        version = fields[0]
        flags = fields[1].delete('-')
        attributes = flags.chars.compact_map { |flag| FLAG_NAMES[flag]? }
        {version, flags, attributes}
      end
    end
  end
end
