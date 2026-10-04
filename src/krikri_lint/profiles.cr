module Krikri
  module Lint
    # Mirrors upstream's data/profiles.yml: profiles extend each other in
    # order min -> basic -> moderate -> safety -> shared -> production,
    # each rule first runs in the profile where it is listed under
    # `rules:` (a `skip_list:` placement means it is still off there).
    module Profile
      NAMES = %w[min basic moderate safety shared official production]

      # Upstream's --profile choices are every profile in data/profiles.yml,
      # "basic" included (cli.py passes PROFILES.keys() straight to argparse).
      SELECTABLE = SUMMARY_PROFILES

      # Upstream's PROFILES keys (data/profiles.yml), in order. NAMES also
      # carries "official", a legacy alias that has no profile of its own
      # upstream, so it must stay out of the summary's profile walk and
      # star rating.
      SUMMARY_PROFILES = %w[min basic moderate safety shared production]

      # How many entries of RULE_ORDER each summary profile contributes,
      # in the same order as SUMMARY_PROFILES.
      PROFILE_GROUP_SIZES = [4, 19, 4, 6, 15, 7]

      # rule id -> lowest profile whose `rules:` list contains it.
      RULE_PROFILES = {
        "syntax-check"                  => "min",
        "name[missing]"                 => "basic",
        "name[casing]"                  => "moderate",
        "name[template]"                => "moderate",
        "name[play]"                    => "basic",
        "command-instead-of-shell"      => "basic",
        "command-instead-of-module"     => "basic",
        "no-changed-when"               => "shared",
        "risky-file-permissions"        => "safety",
        "risky-octal"                   => "safety",
        "fqcn[action-core]"             => "production",
        "yaml[line-length]"             => "basic",
        "yaml[trailing-spaces]"         => "basic",
        "yaml[truthy]"                  => "basic",
        "yaml[comments]"                => "basic",
        "yaml[empty-lines]"             => "basic",
        "yaml[hyphens]"                 => "basic",
        "yaml[indentation]"             => "basic",
        "yaml[key-duplicates]"          => "basic",
        "yaml[new-line-at-end-of-file]" => "basic",
        "yaml[octal-values]"            => "basic",
        "yaml[commas]"                  => "basic",
        "yaml[colons]"                  => "basic",
        "partial-become"                => "basic",
        "no-free-form"                  => "basic",
        "schema[meta]"                  => "basic",
      }

      def self.list : Array(String)
        SELECTABLE
      end

      # Upstream builds `rule_order` by walking data/profiles.yml in file
      # order and recording each profile's *own* rules list, so a rule's
      # index is its position in that flattened concatenation. The
      # summary table sorts its rows by this index, so it has to mirror
      # the upstream file exactly: yaml at 22, package-latest at 29,
      # no-changed-when at 41.
      RULE_ORDER = %w[
        internal-error load-failure parser-error syntax-check
        command-instead-of-module command-instead-of-shell deprecated-bare-vars
        deprecated-local-action deprecated-module inline-env-var key-order
        literal-compare jinja no-free-form no-jinja-when no-tabs partial-become
        playbook-extension role-name schema name var-naming yaml
        name[template] name[imperative] name[casing] spell-var-name
        avoid-implicit latest package-latest risky-file-permissions risky-octal
        risky-shell-pipe
        galaxy ignore-errors layout meta-incorrect meta-no-tags meta-video-links
        meta-version meta-runtime no-changed-when no-changelog no-handler
        no-relative-paths max-block-depth max-tasks unsafe-loop
        avoid-dot-notation sanity fqcn import-task-no-when meta-no-dependencies
        single-entry-point use-loop
      ]

      # Index of a rule - or of a bracketed tag's family - in RULE_ORDER.
      # Unknown rules sort last, like upstream's `idx` fallback.
      def self.order(rule_id : String) : Int32
        idx = RULE_ORDER.index(rule_id) ||
              RULE_ORDER.index(rule_id.split("[").first)
        (idx || RULE_ORDER.size).to_i32
      end

      # The profile that first lists this rule id - or, for a bracketed
      # sub-tag whose family is listed, the family. Mirrors the lookup
      # upstream's report_summary does against `rule_order`.
      def self.of(rule_id : String) : String?
        # RULE_PROFILES wins: it also carries the rules upstream holds
        # in a profile's `skip_list:` (name[template] and friends), which
        # RULE_ORDER cannot express.
        if level = RULE_PROFILES[rule_id]?
          return level
        end
        return profile_group(RULE_ORDER.index(rule_id)) if RULE_ORDER.includes?(rule_id)
        family = rule_id.split("[").first
        profile_group(RULE_ORDER.index(family) || RULE_ORDER.index(rule_id))
      end

      private def self.profile_group(idx : Int32?) : String?
        return nil unless idx
        start = 0
        SUMMARY_PROFILES.each_with_index do |name, i|
          start += PROFILE_GROUP_SIZES[i]
          return name if idx < start
        end
        nil
      end

      def self.valid?(profile : String) : Bool
        SELECTABLE.includes?(profile)
      end

      def self.includes?(profile : String, rule_id : String) : Bool
        # Rules upstream does not list at all only run in the strictest
        # profile, so an unknown rule falls back to "production".
        rule_level = of(rule_id) || "production"
        rule_index = NAMES.index(rule_level) || NAMES.size
        selected_index = NAMES.index(profile) || 0
        rule_index <= selected_index
      end
    end
  end
end
