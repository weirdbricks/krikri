module Krikri
  module Lint
    # Mirrors upstream's data/profiles.yml: profiles extend each other in
    # order min -> basic -> moderate -> safety -> shared -> production,
    # each rule first runs in the profile where it is listed under
    # `rules:` (a `skip_list:` placement means it is still off there).
    module Profile
      NAMES = %w[min basic moderate safety shared official production]

      # User-selectable --profile values (upstream CLI rejects the
      # intermediate "basic").
      SELECTABLE = %w[min moderate safety shared official production]

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
        "schema[meta]"                  => "basic",
      }

      def self.list : Array(String)
        SELECTABLE
      end

      def self.valid?(profile : String) : Bool
        SELECTABLE.includes?(profile)
      end

      def self.includes?(profile : String, rule_id : String) : Bool
        rule_level = RULE_PROFILES[rule_id]? || "production"
        rule_index = NAMES.index(rule_level) || NAMES.size
        selected_index = NAMES.index(profile) || 0
        rule_index <= selected_index
      end
    end
  end
end
