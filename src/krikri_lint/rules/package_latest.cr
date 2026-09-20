module Krikri
  module Lint
    # Upstream parity: ansible-lint's package-latest rule (severity
    # VERY_LOW, tags idempotency). Package managers with state: latest
    # and no version/update_only/only_upgrade/download_only.
    class PackageLatestRule < Rule
      PACKAGE_MANAGERS = %w[
        apk apt bower bundler dnf easy_install gem homebrew
        jenkins_plugin npm openbsd_package openbsd_pkg package pacman
        pear pip pkg5 pkgutil portage slackpkg sorcery swdepot
        win_chocolatey yarn yum zypper
      ]

      def id : String
        "package-latest"
      end

      def severity : Severity
        Severity::VERY_LOW
      end

      def tags : Array(String)
        ["idempotency"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          bare = task.bare_module
          next unless PACKAGE_MANAGERS.includes?(bare) ||
                      PACKAGE_MANAGERS.includes?(task.module_name)
          next if task.has_param?("version")
          next if task.has_param?("update_only") ||
                  task.has_param?("only_upgrade") ||
                  task.has_param?("download_only")
          next unless task.param("state") == "latest"
          violations << Violation.new(file.path, task.line, 0, id, severity,
            "Package installs should not use latest.", task.line)
        end
      end
    end
  end
end
