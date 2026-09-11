require "json"

module Krikri
  module PluginHelpers
    # EasyInstall - pure logic for the easy_install plugin: the
    # easy_install command construction and the installed check the real
    # module uses (`--dry-run` output containing "Downloading" means the
    # package is NOT installed). Split out so this logic is unit-spec-able
    # (execution needs a real host with easy_install, which no spec
    # environment has).
    module EasyInstall
      # executable resolution: explicit absolute path wins, an explicit
      # basename is searched with the virtualenv's bin dir first, else
      # plain "easy_install" (the real module's _get_easy_install).
      def self.resolve_executable(executable : String?, virtualenv : String?) : String
        if executable && !executable.empty?
          return executable if executable.starts_with?("/")
          return "#{virtualenv}/bin/#{executable}" if virtualenv && !virtualenv.empty?
          return executable
        end
        (virtualenv && !virtualenv.empty? ? "#{virtualenv}/bin/easy_install" : "easy_install")
      end

      # arguments before the package name: --upgrade when state=latest
      # (the real module's executable_arguments), then the installed
      # probe's extra --dry-run.
      def self.state_arguments(state : String?) : String
        state == "latest" ? "--upgrade" : ""
      end

      def self.probe_command(executable : String, arguments : Array(String), name : String) : String
        ([executable] + arguments + ["--dry-run", name]).reject(&.empty?).join(" ")
      end

      def self.install_command(executable : String, arguments : Array(String), name : String) : String
        ([executable] + arguments + [name]).reject(&.empty?).join(" ")
      end

      def self.venv_activate_path(virtualenv : String) : String
        "#{virtualenv}/bin/activate"
      end

      def self.venv_create_command(virtualenv_command : String, virtualenv : String, site_packages : Bool) : String
        cmd = "#{virtualenv_command} #{virtualenv}"
        cmd += " --system-site-packages" if site_packages
        cmd
      end

      # The real module's _is_package_installed: "Downloading" in the
      # --dry-run output means easy_install would fetch it, i.e. it is
      # not installed.
      def self.installed?(probe_output : String) : Bool
        !probe_output.includes?("Downloading")
      end
    end
  end
end
