module Krikri
  module Lint
    enum FileType
      PLAYBOOK
      TASKS
      HANDLERS
      DEFAULTS
      VARS
      META
      ROLE
      YAML

      def playbook? : Bool
        self == PLAYBOOK
      end

      def self.from_path(path : String) : FileType
        parts = path.split('/')
        # Files under a role's well-known subdirectories classify by the
        # subdirectory, whatever the file name (upstream lints every
        # yaml file in role tasks/vars/defaults/... dirs).
        if (roles_idx = parts.index("roles")) && parts.size > roles_idx + 2
          type = role_subdir_type(parts[roles_idx + 2])
          return type if type
        end
        main_file_type(parts)
      end

      private def self.role_subdir_type(dir : String) : FileType?
        case dir
        when "tasks"    then TASKS
        when "handlers" then HANDLERS
        when "defaults" then DEFAULTS
        when "vars"     then VARS
        when "meta"     then META
        end
      end

      private def self.main_file_type(parts : Array(String)) : FileType
        case parts.last
        when "main.yml", "main.yaml"
          if parts.size >= 2
            type = role_subdir_type(parts[-2])
            return type if type
          end
        end
        PLAYBOOK
      end
    end
  end
end
