module Krikri
  module PluginHelpers
    # SefcontextCommands - command construction and `semanage fcontext`
    # output parsing for community.general.sefcontext (see
    # plugins/sefcontext.cr). Pure string plumbing mirroring the real
    # module's seobject-backed logic (semanage_fcontext_exists /
    # semanage_fcontext_modify / semanage_fcontext_delete), unit-testable
    # without an SELinux policy store.
    module SefcontextCommands
      # The real module's option_to_file_type_str: seobject's own record
      # spelling for each ftype letter - the exact string `semanage
      # fcontext -l` prints in its middle column.
      FILE_TYPE_STR = {
        "a" => "all files",
        "b" => "block device",
        "c" => "character device",
        "d" => "directory",
        "f" => "regular file",
        "l" => "symbolic link",
        "p" => "named pipe",
        "s" => "socket",
      }

      # semanage fcontext's own -f flag per ftype letter. 'a' is the
      # default (no flag), and a regular file is spelled '--'.
      FILE_TYPE_FLAG = {
        "a" => nil,
        "b" => "b",
        "c" => "c",
        "d" => "d",
        "f" => "--",
        "l" => "l",
        "p" => "p",
        "s" => "s",
      }

      record Record, target : String, ftype_str : String, context : String

      # Parses `semanage fcontext -l` output: three (or more) whitespace
      # separated columns - target, file-type string, SELinux context -
      # with a two-line header. The context may be "<<None>>" for the
      # special no-context mapping; it is kept as the raw string.
      def self.parse_listing(output : String) : Array(Record)
        output.split('\n').compact_map do |line|
          next nil if line.strip.empty?
          next nil if line.strip.starts_with?("SELinux fcontext")
          next nil if line.strip.starts_with?("=")
          parts = line.strip.split(/\s{2,}/)
          next nil unless parts.size >= 3
          Record.new(parts[0], parts[1], parts[2..].join(" "))
        end
      end

      # Parses `semanage fcontext -C -l`'s equivalence lines:
      # "target = substitute".
      def self.parse_equivalences(output : String) : Hash(String, String)
        result = Hash(String, String).new
        output.split('\n').each do |line|
          stripped = line.strip
          next if stripped.empty?
          target, sep, substitute = stripped.partition(" = ")
          next if sep.empty?
          result[target] = substitute
        end
        result
      end

      def self.add_command(target : String, setype : String, ftype : String, seuser : String, serange : String) : Array(String)
        modify_like_command("-a", target, setype, ftype, seuser, serange)
      end

      def self.modify_command(target : String, setype : String, ftype : String, seuser : String, serange : String) : Array(String)
        modify_like_command("-m", target, setype, ftype, seuser, serange)
      end

      def self.delete_command(target : String, ftype : String) : Array(String)
        cmd = ["semanage", "fcontext", "-d"]
        if flag = FILE_TYPE_FLAG[ftype]?
          cmd += ["-f", flag]
        end
        cmd << target
        cmd
      end

      def self.add_equal_command(target : String, substitute : String, modify : Bool) : Array(String)
        ["semanage", "fcontext", modify ? "-m" : "-a", "-e", substitute, target]
      end

      private def self.modify_like_command(flag : String, target : String, setype : String, ftype : String, seuser : String, serange : String) : Array(String)
        cmd = ["semanage", "fcontext", flag, "-t", setype]
        cmd += ["-s", seuser]
        cmd += ["-r", serange]
        if f = FILE_TYPE_FLAG[ftype]?
          cmd += ["-f", f]
        end
        cmd << target
        cmd
      end
    end
  end
end
