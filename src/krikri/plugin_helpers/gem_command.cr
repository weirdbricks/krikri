module Krikri
  module PluginHelpers
    # GemCommand - pure logic for building `gem install`/`gem uninstall`
    # command lines. No I/O here - the plugin itself runs the resulting
    # commands. Verified against real community.general gem.py's own
    # `install`/`uninstall`/`common_opts` source directly (flag order
    # included), not assumed from ansible-doc.
    module GemCommand
      def self.install_command(
        executable : String, name : String, version : String?,
        user_install : Bool, bindir : String?, repository : String?,
        include_dependencies : Bool, norc : Bool,
      ) : String
        String.build do |io|
          io << executable << " install"
          io << " --norc" if norc
          io << " -v \"" << version << "\"" if version
          io << " --source \"" << repository << "\"" if repository
          io << " --ignore-dependencies" unless include_dependencies
          io << (user_install ? " --user-install" : " --no-user-install")
          io << " --bindir \"" << bindir << "\"" if bindir
          io << " --no-document"
          io << " " << name
        end
      end

      def self.uninstall_command(executable : String, name : String, version : String?, norc : Bool) : String
        String.build do |io|
          io << executable << " uninstall"
          io << " --norc" if norc
          io << " " << name << " --executables --force"
          io << " -v \"" << version << "\"" if version
        end
      end

      # Real community.general gem.py's get_installed_versions parser for
      # `gem list` / `gem list --remote` output: each line matching
      # /\S+\s+\((?:default: )?(.+)\)/, versions split on ", ", and only
      # the first token of each kept (strips platform suffixes like
      # "x86_64-linux"). The module's idempotency check is an exact-string
      # membership test of the version param against this list.
      def self.parse_list_versions(output : String) : Array(String)
        versions = [] of String
        output.each_line do |line|
          if match = line.match(/\S+\s+\((?:default: )?(.+)\)/)
            match[1].split(", ").each do |v|
              versions << v.split[0]
            end
          end
        end
        versions
      end
    end
  end
end
