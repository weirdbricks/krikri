require "json"

module CrystalPlay
  module PluginHelpers
    # StatFields - pure logic for turning a raw POSIX `stat`/`lstat` result
    # into the stat-shaped JSON hash both the `stat` and `find` plugins
    # return (`find`'s per-match dicts are documented as "see stat module
    # for full output of each dictionary", verified against real
    # ansible-playbook). No I/O here - the plugin itself calls
    # `LibC.stat`/`LibC.lstat`, resolves pw_name/gr_name via
    # `System::User`/`System::Group`, and merges in readable/writeable/
    # executable/checksum/lnk_* (each needs its own syscall/read the
    # plugin makes itself).
    module StatFields
      # mode here is the *raw* st_mode (type bits + permission bits, e.g.
      # 0o100644 for a 644 regular file) - the same value `LibC::Stat#st_mode`
      # returns, not the type-stripped octal `stat -c %a` used to produce.
      def self.build(
        path : String,
        mode : Int32,
        size : Int64,
        uid : Int64,
        gid : Int64,
        pw_name : String,
        gr_name : String,
        atime : Int64,
        mtime : Int64,
        ctime : Int64,
        inode : Int64,
        dev : Int64,
        nlink : Int64,
      ) : Hash(String, JSON::Any)
        special_digit = (mode >> 9) & 0o7
        owner_digit = (mode >> 6) & 0o7
        group_digit = (mode >> 3) & 0o7
        other_digit = mode & 0o7

        perm_octal = perm_octal(mode)

        file_mode = mode & LibC::S_IFMT

        {
          "exists"  => true,
          "path"    => path,
          "mode"    => "0#{perm_octal}",
          "size"    => size,
          "uid"     => uid,
          "gid"     => gid,
          "pw_name" => pw_name,
          "gr_name" => gr_name,
          "atime"   => atime,
          "mtime"   => mtime,
          "ctime"   => ctime,
          "inode"   => inode,
          "dev"     => dev,
          "nlink"   => nlink,
          "isdir"   => file_mode == LibC::S_IFDIR,
          "isreg"   => file_mode == LibC::S_IFREG,
          "islnk"   => file_mode == LibC::S_IFLNK,
          "isblk"   => file_mode == LibC::S_IFBLK,
          "ischr"   => file_mode == LibC::S_IFCHR,
          "isfifo"  => file_mode == LibC::S_IFIFO,
          "issock"  => file_mode == LibC::S_IFSOCK,
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

      # Matches GNU `stat -c '%a'`: the type bits are stripped and the
      # special (setuid/setgid/sticky) digit is only included when
      # non-zero (e.g. 0o100644 -> "644", 0o104755 -> "4755"). Also used
      # by `file.cr` to compare a freshly-lstat'd mode against a
      # requested numeric `mode:` parameter without shelling to `stat`.
      def self.perm_octal(mode : Int32) : String
        special_digit = (mode >> 9) & 0o7
        owner_digit = (mode >> 6) & 0o7
        group_digit = (mode >> 3) & 0o7
        other_digit = mode & 0o7

        special_digit == 0 ? "#{owner_digit}#{group_digit}#{other_digit}" : "#{special_digit}#{owner_digit}#{group_digit}#{other_digit}"
      end

      def self.regular_file?(mode : Int32) : Bool
        (mode & LibC::S_IFMT) == LibC::S_IFREG
      end

      def self.symlink?(mode : Int32) : Bool
        (mode & LibC::S_IFMT) == LibC::S_IFLNK
      end
    end
  end
end
