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
      # A collection's tests/sanity/ignore-*.txt. Plain text, never YAML.
      SANITY_IGNORE

      def playbook? : Bool
        self == PLAYBOOK
      end

      # Upstream's Lintable.base_kind gate: only a text/yaml lintable
      # reaches the generic matchyaml dispatch. A sanity ignore file is
      # plain text and a role directory is kind "role" with no yaml base
      # kind, so each reaches only a rule that opts in
      # (Rule#non_yaml_lintable? / Rule#applies?).
      def yaml_lintable? : Bool
        self != SANITY_IGNORE && self != ROLE
      end

      # Upstream's kind_from_path glob **/tests/sanity/ignore-*.txt.
      def self.sanity_ignore_path?(path : String) : Bool
        parts = path.split('/')
        return false if parts.size < 3
        name = parts[-1]
        parts[-3] == "tests" && parts[-2] == "sanity" &&
          name.starts_with?("ignore-") && name.ends_with?(".txt")
      end

      def self.from_path(path : String) : FileType
        return SANITY_IGNORE if sanity_ignore_path?(path)
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
