require "../shell"

module Krikri
  module PluginHelpers
    # DpkgDivertCommand - builds the dpkg-divert command lines
    # community.general.dpkg_divert runs, mirroring the MAINCOMMAND
    # construction in the Ansible module's main(). Pure string plumbing so
    # the exact argv shapes are unit-testable without a dpkg database
    # (or a Debian host at all); the plugin itself executes them.
    module DpkgDivertCommand
      record Options,
        state : String,   # "present" / "absent"
        holder : String?, # nil -> --local (LOCAL)
        divert : String?, # nil -> <path>.distrib
        rename : Bool,
        force : Bool

      # The one dpkg-divert invocation that adds/updates/removes the
      # diversion. The Ansible module probes --version for --no-rename
      # support (dpkg >= 1.19.1, 2019) - treated as always-supported
      # here, same reasoning as lvol's --yes shortcut: --no-rename is
      # always passed explicitly unless --rename was asked for.
      #
      # *dpkg_divert* is the get_bin_path(required=True)-resolved binary:
      # the real module builds MAINCOMMAND from the RESOLVED path, so the
      # `commands` its success result records carry "/usr/bin/dpkg-divert
      # ...", not a bare name.
      def self.main_command(options : Options, dpkg_divert : String, path : String) : String
        argv = [dpkg_divert]
        argv << "--rename" if options.rename
        argv << "--no-rename" unless options.rename

        if options.state == "present"
          if (holder = options.holder) && holder != "LOCAL"
            argv += ["--package", holder]
          else
            argv << "--local"
          end
          # --divert is passed ONLY when the task gave one: dpkg-divert
          # itself defaults to <path>.distrib, and the real module's
          # MAINCOMMAND omits the flag then (live-verified vs 2.19.11 in
          # a podman container: commands = ["... --no-rename --local
          # --add <path>"]).
          argv += ["--divert", options.divert] if options.divert
          argv += ["--add", path]
        else
          argv += ["--remove", path]
        end

        argv.join(' ')
      end

      # Inserts --test where the Ansible module puts it (right after the
      # binary, before the action flags) - used both for check mode and
      # for its own "just try and see" probe when the diversion state
      # already matches.
      def self.with_test(command : String) : String
        parts = command.split(' ')
        parts.insert(1, "--test")
        parts.join(' ')
      end

      def self.remove_command(dpkg_divert : String, path : String) : String
        "#{dpkg_divert} --no-rename --remove #{single_quote(path)}"
      end

      def self.version_command(dpkg_divert : String) : String
        "#{dpkg_divert} --version"
      end

      # The two diversion-state probes run through
      # run_command(..., check_rc=True) in the real module, so a non-zero
      # exit fails the module with run_command's own shape - whose cmd
      # field is _clean_args' rendering: the resolved binary with each
      # arg shlex.quote-joined (safe tokens stay bare, so a relative
      # path like `80` reports unquoted). Shell.quote_arg mirrors that
      # quoting; the same string is also shell-safe to execute.
      def self.listpackage_command(dpkg_divert : String, path : String) : String
        "#{dpkg_divert} --listpackage #{Krikri::Shell.quote_arg(path)}"
      end

      def self.truename_command(dpkg_divert : String, path : String) : String
        "#{dpkg_divert} --truename #{Krikri::Shell.quote_arg(path)}"
      end

      private def self.single_quote(s : String) : String
        "'" + s.gsub("'", "'\\''") + "'"
      end
    end
  end
end
