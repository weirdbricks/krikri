module Krikri
  module PluginHelpers
    # Cpanm - pure logic for the cpanm plugin: the cpanm argv and the
    # installed probe of community.general.cpanm, split out so it is
    # unit-spec-able without a Perl toolchain.
    module Cpanm
      def self.install_argv(executable : String, spec : String, notest : Bool, locallib : String?,
                            mirror : String?, mirror_only : Bool, installdeps : Bool) : Array(String)
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
    end
  end
end
