require "json"
require "../base_plugin"

module Krikri
  module PluginHelpers
    # Shared implementation for the RPM-family package-manager plugins
    # (`plugins/yum.cr`, `plugins/dnf.cr`): every method here was a
    # byte-identical (modulo the binary name / comment verbosity) copy
    # in both files, and the copies had already drifted once (yum's
    # install path gained the classify/batch refactor dnf never got).
    # Included as INSTANCE methods into both plugin classes, so they
    # dispatch through the includer's own remote_exec/@params/true? -
    # the only per-plugin input is #pkg_manager_binary, which each
    # plugin defines as a one-liner.
    #
    # NOTE: the two plugins' `execute` and install/absent handling are
    # still per-plugin (yum's install path has the newer classify/batch
    # shape; dnf's is the older monolith) - unify those only as part of
    # a deliberate behavioral alignment, not by wholesale deletion.
    module RpmPackage
      # The package-manager command each includer shells out to ("yum"
      # / "dnf"). Defined by the including plugin class.
      abstract def pkg_manager_binary : String

      private def remote_exec_tolerating_unknown_repo(cmd : String) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
        result = remote_exec(cmd)
        if result[:exit_code] != 0 && (m = result[:stderr].match(/Unknown repo: '([^']+)'/))
          stripped_cmd = cmd.gsub("--enablerepo=#{m[1]}", "").gsub(/  +/, " ")
          return remote_exec_tolerating_unknown_repo(stripped_cmd) if stripped_cmd != cmd
        end
        result
      end

      private def url_or_file?(name : String) : Bool
        name.starts_with?("http://") ||
          name.starts_with?("https://") ||
          name.starts_with?("ftp://") ||
          name.starts_with?("/")
      end

      private def quote_package(name : String) : String
        if name.includes?(" ") || name.includes?(">") || name.includes?("<")
          "'#{name}'"
        else
          name
        end
      end

      private def package_group?(name : String) : Bool
        name.starts_with?("@")
      end

      private def package_installed?(name : String) : Bool
        # Strip version specifiers for checking
        base_name = name.split(/[<>=]/).first.strip

        # Try a plain `rpm -q <name>` first (correctly matches both a
        # bare name and a NEVRA-style "name-version" specifier), falling
        # back to `--whatprovides` (a Provides:/capability lookup) only
        # for a VIRTUAL package name satisfied purely via another real
        # package's `Provides:` (e.g. RHEL 9's `php-json`, bundled into
        # `php-common` since PHP 8.0) - `--whatprovides` ALONE regresses
        # any version-pinned NEVRA name (`rpm -q --whatprovides
        # telegraf-1.18.2` fails even when that exact NEVRA is installed,
        # verified live), so both checks are needed, in this order.
        result = remote_exec("rpm -q #{shell_single_quote(base_name)} 2>/dev/null")
        return true if result[:exit_code] == 0

        result = remote_exec("rpm -q --whatprovides #{shell_single_quote(base_name)} 2>/dev/null")
        result[:exit_code] == 0
      end

      private def handle_autoremove : PluginResult
        options = build_dnf_options
        cmd = "#{pkg_manager_binary} autoremove #{options}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        success = result[:exit_code] == 0

        if success
          changed = result[:stdout].includes?("Removed:")

          msg = changed ? "Removed unneeded packages" : "No unneeded packages to remove"

          PluginResult.new(
            changed: changed,
            failed: false,
            msg: msg,
            stdout: result[:stdout],
            exit_code: 0
          )
        else
          PluginResult.new(
            changed: false,
            failed: true,
            msg: "Autoremove failed",
            stdout: result[:stdout],
            stderr: result[:stderr],
            exit_code: result[:exit_code]
          )
        end
      end

      private def handle_upgrade_all : PluginResult
        options = build_dnf_options
        cmd = "#{pkg_manager_binary} upgrade #{options}"

        result = remote_exec_tolerating_unknown_repo(cmd)

        success = result[:exit_code] == 0

        if success
          changed = result[:stdout].includes?("Upgraded:") ||
                    result[:stdout].includes?("Installed:")

          msg = changed ? "System upgraded" : "All packages already up to date"

          PluginResult.new(
            changed: changed,
            failed: false,
            msg: msg,
            stdout: result[:stdout],
            exit_code: 0
          )
        else
          PluginResult.new(
            changed: false,
            failed: true,
            msg: "Failed to upgrade system",
            stdout: result[:stdout],
            stderr: result[:stderr],
            exit_code: result[:exit_code]
          )
        end
      end

      private def build_dnf_options : String
        options = [] of String

        # Always use -y for non-interactive
        options << "-y"

        # Enable/disable repos
        if enablerepo = @params["enablerepo"]?
          enablerepo.split(",").each do |repo|
            options << "--enablerepo=#{repo.strip}"
          end
        end

        if disablerepo = @params["disablerepo"]?
          disablerepo.split(",").each do |repo|
            options << "--disablerepo=#{repo.strip}"
          end
        end

        # GPG check - real ansible's dnf module explicitly sets BOTH
        # conf.gpgcheck AND conf.localpkg_gpgcheck to `not disable_gpg_check`
        # (verified in ansible-core's own dnf.py: "conf.localpkg_gpgcheck =
        # not disable_gpg_check"), overriding dnf's own actual default for
        # local/URL package installs, which is gpgcheck-OFF regardless of
        # the repo gpgcheck=1 setting in dnf.conf. Plain `--nogpgcheck` only
        # covers the repo-package path; without also forcing
        # `--setopt=localpkg_gpgcheck=1` here, a `name: https://.../foo.rpm`
        # install silently skipped signature verification (inherited dnf's
        # own default), diverging from real ansible-playbook which
        # correctly refuses an RPM whose signing key isn't imported. Found
        # benchmarking geerlingguy.selenium's "Install Chrome (if
        # configured, RedHat)" task (direct google-chrome-stable RPM URL,
        # no imported key) - real ansible failed with "Failed to validate
        # GPG signature", krikri-playbook installed it anyway.
        if true?(@params["disable_gpg_check"]?)
          options << "--nogpgcheck"
        else
          options << "--setopt=localpkg_gpgcheck=1"
        end

        # Security/bugfix updates
        if true?(@params["security"]?)
          options << "--security"
        end

        if true?(@params["bugfix"]?)
          options << "--bugfix"
        end

        # Weak dependencies
        if false?(@params["install_weak_deps"]?)
          options << "--setopt=install_weak_deps=False"
        end

        # Skip broken packages
        if true?(@params["skip_broken"]?)
          options << "--skip-broken"
        end

        # Allow downgrade
        if true?(@params["allow_downgrade"]?)
          options << "--allowerasing"
        end

        # Best (default in dnf, but explicit is good)
        options << "--best" unless true?(@params["skip_broken"]?)

        options.join(" ")
      end
    end
  end
end
