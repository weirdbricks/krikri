module Krikri
  module Lint
    # Upstream parity: ansible-lint's fqcn[canonical] sub-rule. When a
    # fully-qualified module name resolves through Ansible's redirect
    # chain to a different canonical FQCN, flag the written name.
    # Redirects observed with the installed collections; new ones land
    # here when the parity corpus finds them.
    class FqcnCanonicalRule < Rule
      REDIRECTS = {
        "ansible.builtin.acl"             => "ansible.posix.acl",
        "ansible.builtin.cronvar"         => "community.general.cronvar",
        "community.mysql.mysql_query"     => "ansible.mysql.mysql_query",
        "community.mysql.mysql_variables" => "ansible.mysql.mysql_variables",
        "community.mysql.mysql_user"      => "ansible.mysql.mysql_user",
        "community.mysql.mysql_info"      => "ansible.mysql.mysql_info",
        "community.mysql.mysql_db"        => "ansible.mysql.mysql_db",
      }

      def id : String
        "fqcn[canonical]"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["autofix", "formatting"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def fixable? : Bool
        true
      end

      def fix(buffer : FixBuffer, file : PositionedFile, violation : Violation) : Bool
        TaskWalker.each_task(file) do |task|
          next unless task.action_line == violation.line &&
                      task.action_column == violation.column
          canonical = REDIRECTS[task.module_name]? || return false
          return false unless buffer.line_text(violation.line)
          return buffer.replace_span(violation.line, violation.column,
            task.module_name.size, canonical)
        end
        false
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          module_name = task.module_name
          next unless module_name.count('.') >= 2
          next unless canonical = REDIRECTS[module_name]?
          violations << Violation.new(file.path, task.action_line,
            task.action_column, id, severity,
            "You should use canonical module name `#{canonical}` instead of `#{module_name}`.",
            task.line)
        end
      end
    end
  end
end
