require "../shell"

module Krikri
  module PluginHelpers
    # GemCommand - pure logic for building `gem install`/`gem uninstall`
    # command lines. No I/O here - the plugin itself runs the resulting
    # commands. Verified against real community.general gem.py's CmdRunner
    # arg_formats/args_order (flag order included), and against the argv a
    # logging shim observed real ansible-playbook feed `gem` (the *joined*
    # argv is what a run_command failure reports as its `cmd` - krikri
    # shells these through bash, so the strings here must both work as
    # shell and READ like ansible's space-joined argv, hence the unquoted
    # `--version`/name pattern: gem versions and names carry no shell
    # metacharacters).
    module GemCommand
      # *target* is the module's gem_source (which real gem.py defaults to
      # name): the install positional, never name itself. *include_doc*
      # defaults to FALSE in real's argument_spec, so the common case adds
      # --no-document and an explicit include_doc: true omits it.
      def self.install_command(
        executable : String, target : String, version : String?,
        user_install : Bool, bindir : String?, repository : String?,
        include_dependencies : Bool, norc : Bool,
        pre_release : Bool = false, include_doc : Bool = false,
        env_shebang : Bool = false, build_flags : String? = nil,
        force : Bool = false,
      ) : String
        String.build do |io|
          io << executable << " install"
          io << " --norc" if norc
          io << " --version " << version if version
          io << " --source \"" << repository << "\"" if repository
          io << " --ignore-dependencies" unless include_dependencies
          io << (user_install ? " --user-install" : " --no-user-install")
          io << " --bindir \"" << bindir << "\"" if bindir
          io << " --pre" if pre_release
          io << " --no-document" unless include_doc
          io << " --env-shebang" if env_shebang
          # gem_source and build_flags are each ONE argv element in real
          # (fmt.as_list / as_opt_val), so a path or flag string with a
          # space must not word-split; quote_arg also reproduces the
          # quoting shlex.join puts in real's displayed cmd.
          io << " " << Shell.quote_arg(target)
          io << " -- " << Shell.quote_arg(build_flags) if build_flags
          io << " --force" if force
        end
      end

      def self.uninstall_command(executable : String, name : String, version : String?, norc : Bool, force : Bool = false) : String
        # Real uninstall's args_order: subcmd, norc, install_dir, bindir,
        # version (--version X, or --all when no version), --executable
        # (as_fixed - always emitted), force (only when the force param is
        # set), name.
        String.build do |io|
          io << executable << " uninstall"
          io << " --norc" if norc
          if version
            io << " --version " << version
          else
            io << " --all"
          end
          io << " --executable"
          io << " --force" if force
          io << " " << name
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
