require "yaml"
require "./file_type"

module Krikri
  module Lint
    # `.ansible-lint` config file plus its CLI flag overrides.
    struct LintConfig
      getter skip_list : Array(String)
      getter warn_list : Array(String)
      getter enable_list : Array(String)
      getter tags : Array(String)
      getter exclude_paths : Array(String)
      getter profile : String
      getter config_dir : String
      # Project-declared kind assignments, in file order. Upstream
      # prepends them to its default patterns, so the first match wins.
      getter kinds : Array(KindPattern)
      # Opt-in regex a role loop's loop_control.loop_var must match, with
      # `{role}` standing for the role's toidentifier'd name. nil (the
      # upstream default) disables loop-var-prefix entirely.
      getter loop_var_prefix : String?
      # The warn_list a config file defined, nil when it had none (and
      # the defaults stand); lets the CLI merge reproduce upstream's
      # "CLI list, extended with the file's" behavior exactly.
      getter file_warn_list : Array(String)?

      # Upstream's DEFAULT_WARN_LIST (ansiblelint/config.py): rules in
      # here render as warnings and count under warnings in the summary
      # instead of as failures, unless a config file provides its own
      # warn_list (which replaces the defaults wholesale; upstream's
      # merge_config extends only a CLI-provided list onto the file's).
      DEFAULT_WARN_LIST = ["experimental", "jinja[spacing]", "fqcn[deep]"]

      def initialize(@skip_list = [] of String,
                     @warn_list = DEFAULT_WARN_LIST.dup,
                     @enable_list = [] of String, @tags = [] of String,
                     @exclude_paths = [] of String, @profile = "production",
                     @config_dir = ".",
                     @file_warn_list : Array(String)? = nil,
                     @kinds = [] of KindPattern,
                     @loop_var_prefix : String? = nil)
      end

      # Excluded paths are dropped before linting, so they are neither
      # reported nor counted in the summary's file total.
      def excluded?(path : String) : Bool
        @exclude_paths.any? do |ex|
          pattern = ex.ends_with?("/") ? ex : ex + "/"
          path.starts_with?(pattern) || path.starts_with?(File.expand_path(pattern))
        end
      end

      # Searches cwd upward for a .ansible-lint file, like upstream's
      # project-dir discovery.
      def self.discover : LintConfig
        dir = Dir.current
        while true
          candidate = File.join(dir, ".ansible-lint")
          if File.exists?(candidate)
            return from_file(candidate)
          end
          parent = File.dirname(dir)
          break if parent == dir
          dir = parent
        end
        LintConfig.new
      end

      def self.from_file(path : String) : LintConfig
        data = parse_config_file(path)
        dir = File.dirname(path)
        return LintConfig.new(config_dir: dir) unless data
        apply_config(data, dir)
      end

      private def self.parse_config_file(path : String) : Hash(YAML::Any, YAML::Any)?
        begin
          YAML.parse(File.read(path)).as_h?
        rescue ex : YAML::ParseException
          STDERR.puts "krikri-lint: invalid config #{path}: #{ex.message}"
          exit 3
        end
      end

      private def self.apply_config(data : Hash(YAML::Any, YAML::Any), dir : String) : LintConfig
        # A config file's own warn_list replaces the defaults wholesale,
        # and file_warn_list keeps it so the CLI merge can extend it.
        file_warn_list = string_list(data["warn_list"]?)
        LintConfig.new(
          skip_list: string_list(data["skip_list"]?) || [] of String,
          warn_list: file_warn_list || DEFAULT_WARN_LIST.dup,
          exclude_paths: string_list(data["exclude_paths"]?) || [] of String,
          profile: data["profile"]?.try(&.as_s?) || "production",
          config_dir: dir,
          file_warn_list: file_warn_list,
          kinds: data["kinds"]?.try(&.as_a?).try { |list| parse_kinds(list) } || [] of KindPattern,
          loop_var_prefix: data["loop_var_prefix"]?.try(&.as_s?))
      end

      private def self.string_list(value : YAML::Any?) : Array(String)?
        value.try(&.as_a?).try(&.map(&.as_s))
      end

      # `kinds:` is a list of one-entry mappings (upstream's shape):
      # `- playbook: "**/*.play"`. Entries it cannot read are ignored.
      private def self.parse_kinds(list : Array(YAML::Any)) : Array(KindPattern)
        kinds = [] of KindPattern
        list.each do |item|
          entry = item.as_h? || next
          entry.each do |name, pattern|
            next unless glob = pattern.as_s?
            kinds << KindPattern.new(name.as_s, glob)
          end
        end
        kinds
      end
    end
  end
end
