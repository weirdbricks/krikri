module Krikri
  module Lint
    # Upstream parity: ansible-lint's command-instead-of-module
    # (severity HIGH, tags command-shell/idiom). Flags command:/shell:
    # tasks whose first command word is an executable an Ansible module
    # covers, with upstream's second-argument exemptions.
    class CommandInsteadOfModuleRule < Rule
      COMMAND_MODULES = %w[command shell]

      MODULES = {
        "apt-get"       => "apt-get",
        "chkconfig"     => "service",
        "curl"          => "get_url or uri",
        "git"           => "git",
        "hg"            => "hg",
        "letsencrypt"   => "acme_certificate",
        "mktemp"        => "tempfile",
        "mount"         => "mount",
        "patch"         => "patch",
        "rpm"           => "yum or rpm_key",
        "rsync"         => "synchronize",
        "sed"           => "template, replace or lineinfile",
        "service"       => "service",
        "supervisorctl" => "supervisorctl",
        "svn"           => "subversion",
        "systemctl"     => "systemd",
        "tar"           => "unarchive",
        "unzip"         => "unarchive",
        "wget"          => "get_url or uri",
        "yum"           => "yum",
      }

      EXECUTABLE_OPTIONS = {
        "git"       => %w[branch log lfs rev-parse clean],
        "systemctl" => %w[--version get-default kill set-default set-property
          set-environment unset-environment show-environment
          status reset-failed],
        "yum" => %w[clean history info],
        "rpm" => %w[--nodeps],
      }

      def id : String
        "command-instead-of-module"
      end

      def severity : Severity
        Severity::HIGH
      end

      def tags : Array(String)
        ["command-shell", "idiom"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          next unless COMMAND_MODULES.includes?(task.bare_module)
          args = command_args(task)
          first = args.first? || next
          executable = File.basename(first)
          second = args[1]?
          if second && (allowed = EXECUTABLE_OPTIONS[executable]?) && allowed.includes?(second)
            next
          end
          next unless replacement = MODULES[executable]?
          violations << Violation.new(
            file.path, task.line, NodeUtil.column(task.node), id, severity,
            "#{executable} used in place of #{replacement} module"
          )
        end
      end

      private def command_args(task : LintTask) : Array(String)
        text = task.param("cmd") || task.param("_raw_params") || free_form_text(task)
        return [] of String unless text
        text.split(/\s+/).reject(&.empty?).reject { |arg| arg.includes?("{{") }
      end

      # Free-form action form: `command: echo hi` (scalar) or the first
      # string in a list form.
      private def free_form_text(task : LintTask) : String?
        action = task.action_node
        if action.is_a?(YAML::Nodes::Scalar)
          return action.value
        end
        if action.is_a?(YAML::Nodes::Sequence)
          action.nodes.each do |item|
            if item.is_a?(YAML::Nodes::Scalar) && (v = item.value)
              return v
            end
          end
        end
        nil
      end
    end
  end
end
