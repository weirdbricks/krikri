module Krikri
  module PluginHelpers
    # DpkgDivertCommand - builds the dpkg-divert command lines
    # community.general.dpkg_divert runs, mirroring the MAINCOMMAND
    # construction in the real module's main(). Pure string plumbing so
    # the exact argv shapes are unit-testable without a dpkg database
    # (or a Debian host at all); the plugin itself executes them.
    module DpkgDivertCommand
      record Options,
        state : String,            # "present" / "absent"
        holder : String?,          # nil -> --local (LOCAL)
        divert : String?,          # nil -> <path>.distrib
        rename : Bool,
        force : Bool

      # The one dpkg-divert invocation that adds/updates/removes the
      # diversion. The real module probes --version for --no-rename
      # support (dpkg >= 1.19.1, 2019) - treated as always-supported
      # here, same reasoning as lvol's --yes shortcut: --no-rename is
      # always passed explicitly unless --rename was asked for.
      def self.main_command(options : Options, path : String) : String
        argv = ["dpkg-divert"]
        argv << "--rename" if options.rename
        argv << "--no-rename" unless options.rename

        if options.state == "present"
          if (holder = options.holder) && holder != "LOCAL"
            argv += ["--package", holder]
          else
            argv << "--local"
          end
          argv += ["--divert", options.divert || "#{path}.distrib"]
          argv += ["--add", path]
        else
          argv += ["--remove", path]
        end

        argv.join(' ')
      end

      # Inserts --test where the real module puts it (right after the
      # binary, before the action flags) - used both for check mode and
      # for its own "just try and see" probe when the diversion state
      # already matches.
      def self.with_test(command : String) : String
        parts = command.split(' ')
        parts.insert(1, "--test")
        parts.join(' ')
      end

      def self.remove_command(path : String) : String
        "dpkg-divert --no-rename --remove #{single_quote(path)}"
      end

      def self.version_command : String
        "dpkg-divert --version"
      end

      def self.listpackage_command(path : String) : String
        "dpkg-divert --listpackage #{single_quote(path)}"
      end

      def self.truename_command(path : String) : String
        "dpkg-divert --truename #{single_quote(path)}"
      end

      private def self.single_quote(s : String) : String
        "'" + s.gsub("'", "'\\''") + "'"
      end
    end
  end
end
