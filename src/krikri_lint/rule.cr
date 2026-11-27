module Krikri
  module Lint
    abstract class Rule
      abstract def id : String
      abstract def severity : Severity
      abstract def tags : Array(String)
      abstract def applies_to : Array(FileType)
      abstract def check(file : PositionedFile, violations : Array(Violation))

      def applies?(file : PositionedFile) : Bool
        return false unless applies_to.includes?(file.file_type)
        return false if file.file_type.unknown?
        # Upstream's matchyaml/matchtasks dispatch skips any lintable
        # whose base_kind is not text/yaml (a path pattern alone does not
        # make a file yaml), so a plain-text sanity ignore file reaches
        # only a rule that opts in to it. A role directory has no yaml
        # base kind either: it reaches only the rules upstream calls
        # through matchdir.
        return true if file.file_type == FileType::ROLE && role_lintable?
        return true if non_yaml_lintable?
        return false unless file.file_type.yaml_lintable?
        !base_kind_gated? || file.base_yaml?
      end

      # Whether upstream's base-kind gate applies to this rule. The gate
      # is part of the inherited matchyaml, so a rule that overrides
      # matchyaml without it keys off the explicit kind alone.
      def base_kind_gated? : Bool
        true
      end

      # Whether this rule inspects a role directory target. Upstream
      # dispatches those to matchdir rather than matchyaml.
      def role_lintable? : Bool
        false
      end

      # Whether this rule inspects a non-YAML lintable (sanity ignore
      # files). Upstream's sanity rule overrides matchyaml wholesale
      # instead of relying on the generic text/yaml gate.
      def non_yaml_lintable? : Bool
        false
      end

      # Upstream's "opt-in" tag: the rule loader keeps such a rule out of
      # the run unless --enable-list names it. The runner needs this
      # explicitly because Profile.includes? treats a rule no profile
      # lists as production, which would turn an opt-in rule on by
      # default.
      def opt_in? : Bool
        tags.includes?("opt-in")
      end

      # Whether this rule's violations belong to an enclosing task, and
      # so are suppressed by a `# noqa:` appearing anywhere inside that
      # task's body. Upstream separates these: matchtask results are
      # filtered by the task's own skip list, while matchyaml results
      # (the yaml[*] family, load-failure) only honour a comment on the
      # violation's own line. Rules that walk tasks (TaskWalker) are
      # task-scoped; file-level rules are not.
      def task_scoped? : Bool
        false
      end

      # Autofix support, mirroring upstream's TransformMixin: a rule
      # opts in by overriding fixable? (and carrying the "autofix" tag
      # like upstream does) and implementing fix. fix must only make
      # line-local edits through the FixBuffer (replace spans within
      # existing lines, delete whole lines, add the final newline);
      # returning true marks the violation fixed so the CLI drops it
      # from the report.
      def fixable? : Bool
        false
      end

      def fix(buffer : FixBuffer, file : PositionedFile, violation : Violation) : Bool
        false
      end

      # Upstream's TransformMixin: the --fix transformer attempts a
      # rule-specific transform for matches of these rules, even when
      # krikri has no line fix of its own (upstream's yaml transform is
      # a documented no-op, yet every yaml[*] match gets a "Rule
      # specific fix not applied for" ERROR from it).
      def transformable? : Bool
        false
      end

      # Whether upstream's transform marks the given violation fixed.
      # Transformable rules that do not mark it fixed get an
      # "Rule specific fix not applied for" ERROR logged for the match.
      def marks_fixed?(violation : Violation) : Bool
        false
      end
    end
  end
end
