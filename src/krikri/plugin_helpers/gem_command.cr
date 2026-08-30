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
    end
  end
end
