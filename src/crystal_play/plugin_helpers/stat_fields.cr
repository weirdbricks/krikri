require "json"

module CrystalPlay
  module PluginHelpers
    # StatFields - pure logic for turning the output of
    # `stat -c '%a|%s|%Y|%X|%Z|%i|%d|%h|%u|%g|%U|%G|%F' <path>` into the
    # stat-shaped JSON hash both the `stat` and `find` plugins return
    # (`find`'s per-match dicts are documented as "see stat module for full
    # output of each dictionary", verified against real ansible-playbook).
    # No I/O here - readable/writeable/executable/checksum/lnk_* need a
    # `test`/`readlink`/`*sum` call the plugin makes itself and merges in.
    module StatFields
      FIELD_COUNT = 13

      # Splits and parses one `stat -c` output line (as above) for `path`
      # into the base stat fields. Returns nil if the output doesn't have
      # the expected number of fields (corrupt/unexpected `stat` output).
      def self.parse(path : String, stat_output : String) : Hash(String, JSON::Any)?
        fields = stat_output.strip.split("|")
        return nil unless fields.size == FIELD_COUNT

        a, size, mtime, atime, ctime, inode, dev, nlink, uid, gid, pw_name, gr_name = fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8], fields[9], fields[10], fields[11]
        file_type = fields[-1]

        owner_digit = a[-3].to_i(8)
        group_digit = a[-2].to_i(8)
        other_digit = a[-1].to_i(8)
        special_digit = a.size == 4 ? a[0].to_i(8) : 0

        {
          "exists"  => true,
          "path"    => path,
          "mode"    => "0#{a}",
          "size"    => size.to_i64,
          "uid"     => uid.to_i64,
          "gid"     => gid.to_i64,
          "pw_name" => pw_name,
          "gr_name" => gr_name,
          "atime"   => atime.to_i64,
          "mtime"   => mtime.to_i64,
          "ctime"   => ctime.to_i64,
          "inode"   => inode.to_i64,
          "dev"     => dev.to_i64,
          "nlink"   => nlink.to_i64,
          "isdir"   => file_type == "directory",
          "isreg"   => file_type == "regular file" || file_type == "regular empty file",
          "islnk"   => file_type == "symbolic link",
          "isblk"   => file_type == "block special file",
          "ischr"   => file_type == "character special file",
          "isfifo"  => file_type == "fifo",
          "issock"  => file_type == "socket",
          "isuid"   => (special_digit & 4) != 0,
          "isgid"   => (special_digit & 2) != 0,
          "rusr"    => (owner_digit & 4) != 0,
          "wusr"    => (owner_digit & 2) != 0,
          "xusr"    => (owner_digit & 1) != 0,
          "rgrp"    => (group_digit & 4) != 0,
          "wgrp"    => (group_digit & 2) != 0,
          "xgrp"    => (group_digit & 1) != 0,
          "roth"    => (other_digit & 4) != 0,
          "woth"    => (other_digit & 2) != 0,
          "xoth"    => (other_digit & 1) != 0,
        }.transform_values { |v| JSON.parse(v.to_json) }
      end

      # The file-type word (last field of the parsed output, e.g. "symbolic
      # link", "directory", "regular file") - callers use this to decide
      # whether to add checksum/lnk_* fields, without re-splitting.
      def self.file_type(stat_output : String) : String?
        fields = stat_output.strip.split("|")
        return nil unless fields.size == FIELD_COUNT
        fields[-1]
      end

      def self.regular_file?(file_type : String) : Bool
        file_type == "regular file" || file_type == "regular empty file"
      end

      def self.symlink?(file_type : String) : Bool
        file_type == "symbolic link"
      end
    end
  end
end
