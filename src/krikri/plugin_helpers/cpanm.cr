module Krikri
  module PluginHelpers
    # Cpanm - pure logic for the cpanm plugin: the cpanm argv, the
    # installed probe and the argument/version-spec validation of
    # community.general.cpanm, split out so it is unit-spec-able without a
    # Perl toolchain.
    module Cpanm
      # The module's `mode` choices; community.general 9.0.0 made "new"
      # the default and deprecated "compatibility".
      MODES        = ["compatibility", "new"]
      DEFAULT_MODE = "new"

      # `command_args_formats` order: notest, locallib, mirror, mirror_only,
      # installdeps, install_recommendations, install_suggestions, pkg_spec.
      # The two recommendation flags are tri-state (as_bool(.., ignore_none)):
      # nil omits them, true/false pick --with-*/--without-*.
      def self.install_argv(executable : String, spec : String, notest : Bool, locallib : String?,
                            mirror : String?, mirror_only : Bool, installdeps : Bool,
                            install_recommendations : Bool? = nil,
                            install_suggestions : Bool? = nil) : Array(String)
        argv = [executable]
        argv << "--notest" if notest
        if locallib && !locallib.empty?
          argv << "--local-lib"
          argv << locallib
        end
        if mirror && !mirror.empty?
          argv << "--mirror"
          argv << mirror
        end
        argv << "--mirror-only" if mirror_only
        argv << "--installdeps" if installdeps
        unless install_recommendations.nil?
          argv << (install_recommendations ? "--with-recommends" : "--without-recommends")
        end
        unless install_suggestions.nil?
          argv << (install_suggestions ? "--with-suggests" : "--without-suggests")
        end
        argv << spec
        argv
      end

      # The module's _is_package_installed: a tarball is never "installed",
      # otherwise `perl -le 'use <name> <version>; print "OK";'` succeeding.
      def self.probe_command(name : String, version : String?, locallib : String?) : String?
        return nil if name.ends_with?(".tar.gz")
        use = version && !version.empty? ? "#{name} #{version}" : name
        cmd = "perl -le #{Process.quote("use #{use}; print \"OK\";")}"
        if locallib && !locallib.empty?
          cmd = "PERL5LIB=#{Process.quote("#{locallib}/lib/perl5")} #{cmd}"
        end
        cmd
      end

      def self.changed?(rc : Int32, stdout : String, stderr : String) : Bool
        rc == 0 && !stdout.includes?("is up to date") && !stderr.includes?("is up to date")
      end

      # __init_module__ refuses these combinations before it resolves or
      # runs cpanm at all, so they surface with no cpanm binary/version in
      # the result. mode=new took from_path as an alternative to name and
      # treats giving both as an error; name_check only exists in mode=new.
      def self.argument_error(mode : String, name : String?, from_path : String?,
                              name_check : String?) : String?
        if mode == "new"
          return "Parameters 'name' and 'from_path' are mutually exclusive when 'mode=new'" if name && from_path
        elsif name_check
          return "Parameter name_check can only be used with mode=new"
        end
        nil
      end

      # sanitize_pkg_spec_version's rejections, in the module's check order.
      # *directory* is os.path.isdir's answer for the spec on the target.
      def self.spec_version_error(pkg_spec : String, version : String, directory : Bool) : String?
        return "parameter 'version' must not be used when installing from a file" if pkg_spec.ends_with?(".tar.gz")
        return "parameter 'version' must not be used when installing from a directory" if directory
        if pkg_spec.ends_with?(".git") && version.starts_with?('~')
          return "operator '~' not allowed in version parameter when installing from git repository"
        end
        nil
      end

      # sanitize_pkg_spec_version: mode=new folds the version into the
      # package spec instead of probing for it, using cpanm's own operators
      # (`~` for a CPAN version, `@` for a git ref).
      def self.versioned_spec(pkg_spec : String, version : String) : String
        if pkg_spec.ends_with?(".git")
          return pkg_spec + (version.starts_with?('@') ? version : "@#{version}")
        end
        return pkg_spec + version if version.starts_with?('@') || version.starts_with?('~')
        "#{pkg_spec}~#{version}"
      end
    end
  end
end
