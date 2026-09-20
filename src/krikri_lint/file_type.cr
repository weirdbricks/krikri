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
        case parts.last
        when "main.yml", "main.yaml"
          if parts.size >= 2
            case parts[-2]
            when "tasks"    then return TASKS
            when "handlers" then return HANDLERS
            when "defaults" then return DEFAULTS
            when "vars"     then return VARS
            when "meta"     then return META
            end
          end
        end
        PLAYBOOK
      end
    end
  end
end
