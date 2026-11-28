module Krikri
  module Lint
    # One entry from a project's `kinds:` config: a kind name and the
    # glob ansible-lint resolves it with. Upstream prepends these to its
    # own defaults ("append default kinds to the custom list"), so a
    # project pattern wins over every default assignment.
    record KindPattern, kind : String, pattern : String

    enum FileType
      PLAYBOOK
      TASKS
      HANDLERS
      DEFAULTS
      VARS
      META
      # Upstream's kind_from_path maps **/meta/runtime.{yaml,yml} to the
      # dedicated "meta-runtime" kind, so that rule sees it instead of
      # whatever a role's meta/ dir would give any other file.
      META_RUNTIME
      # A collection's galaxy.yml. Upstream gives it a kind of its own
      # because every galaxy rule gates on `file.kind == "galaxy"`, and
      # because the playbook syntax check must never load it as a play.
      GALAXY
      ROLE
      YAML
      # A collection's tests/sanity/ignore-*.txt. Plain text, never YAML.
      SANITY_IGNORE
      # Upstream's kind_from_path returns an empty kind for a path no
      # pattern matches, and a lintable with no kind runs no rules at
      # all. That is observable through an explicitly named file target:
      # ansible-lint lints an extensionless playbook without reporting
      # anything about it.
      UNKNOWN

      def playbook? : Bool
        self == PLAYBOOK
      end

      def unknown? : Bool
        self == UNKNOWN
      end

      # A kind krikri can dispatch yaml rules for. Upstream additionally
      # gates them on the lintable's base kind (see
      # PositionedFile#base_yaml?): a sanity ignore file is plain text, a
      # role directory is kind "role" with no yaml base kind, and an
      # unmatched path has no kind at all, so each reaches only a rule
      # that opts in (Rule#non_yaml_lintable? / Rule#applies?).
      def yaml_lintable? : Bool
        self != SANITY_IGNORE && self != ROLE && self != UNKNOWN
      end

      # Upstream's kind_from_path glob **/tests/sanity/ignore-*.txt.
      def self.sanity_ignore_path?(path : String) : Bool
        parts = path.split('/')
        return false if parts.size < 3
        name = parts[-1]
        parts[-3] == "tests" && parts[-2] == "sanity" &&
          name.starts_with?("ignore-") && name.ends_with?(".txt")
      end

      # Upstream's `**/meta/runtime.{yaml,yml}` default pattern, which
      # wins over the generic role/ yaml assignment.
      def self.meta_runtime_path?(path : String) : Bool
        parts = path.split('/')
        return false if parts.size < 2
        name = parts[-1]
        (name == "runtime.yml" || name == "runtime.yaml") && parts[-2] == "meta"
      end

      # Upstream's `**/galaxy.yml` default pattern. Its only spelling is
      # the .yml one: a galaxy.yaml falls through to the generic yaml
      # assignment and is linted as a playbook there.
      def self.galaxy_path?(path : String) : Bool
        File.basename(path) == "galaxy.yml"
      end

      # The role's directory name for a file under roles/<name>/..., nil
      # when the path is outside any roles/ directory. Upstream's
      # Lintable.role walks up to the innermost enclosing roles/ dir, so
      # a nested roles/ tree reports the innermost role.
      def self.role_name(path : String) : String?
        parts = path.split('/')
        idx = parts.rindex("roles") || return nil
        parts[idx + 1]?
      end

      # Upstream's BASE_KINDS assign text/yaml from the name alone: the
      # yaml extensions plus the two config-file names. The base kind,
      # not the kind, decides whether yaml/task rules run.
      def self.text_yaml_name?(path : String) : Bool
        name = File.basename(path)
        yaml_extension?(name) || name == ".ansible-lint" || name == ".yamllint"
      end

      def self.yaml_extension?(name : String) : Bool
        name.ends_with?(".yml") || name.ends_with?(".yaml")
      end

      def self.from_path(path : String, kinds : Array(KindPattern) = [] of KindPattern) : FileType
        # Upstream resolves the path before globbing it, and its patterns
        # are absolute (`**/`-prefixed).
        absolute = File.exists?(path) ? File.realpath(path) : File.expand_path(path)
        # Project kinds come first, then the defaults below.
        kinds.each do |entry|
          return from_kind_name(entry.kind) if File.match?(entry.pattern, absolute)
        end
        # Upstream's galaxy pattern sits ahead of its role/vars/tasks ones,
        # so a galaxy.yml keeps the galaxy kind even inside a role subdir.
        return GALAXY if galaxy_path?(path)
        return SANITY_IGNORE if sanity_ignore_path?(path)
        return META_RUNTIME if meta_runtime_path?(path)
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

      # A kind name krikri has no dedicated rules for (upstream's text,
      # python, inventory, ... kinds, or a project's own name) runs
      # nothing here: every rule distinguishes those kinds from the ones
      # above, and krikri does not implement any of them.
      private def self.from_kind_name(name : String) : FileType
        case name
        when "playbook"           then PLAYBOOK
        when "tasks"              then TASKS
        when "handlers"           then HANDLERS
        when "vars"               then VARS
        when "meta"               then META
        when "meta-runtime"       then META_RUNTIME
        when "galaxy"             then GALAXY
        when "role"               then ROLE
        when "yaml"               then YAML
        when "sanity-ignore-file" then SANITY_IGNORE
        else                           UNKNOWN
        end
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
        when "runtime.yml", "runtime.yaml"
          # Upstream's `**/meta/runtime.{yml,yaml}` kind pattern (kind
          # meta-runtime) matches anywhere, which is how a collection's
          # own meta/runtime.yml - never under roles/ - reaches the
          # meta-runtime rule.
          return META if parts.size >= 2 && parts[-2] == "meta"
        end
        # Upstream's default `**/*.{yaml,yml}` assignment keeps a yaml
        # file lintable when no more specific pattern names it; krikri
        # folds that generic kind into PLAYBOOK, whose rules are the
        # ones that then apply. Anything else matches no default pattern
        # and is unknown upstream.
        yaml_extension?(parts.last) ? PLAYBOOK : UNKNOWN
      end
    end
  end
end
