require "yaml"

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
                     @file_warn_list : Array(String)? = nil)
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
        config = LintConfig.new(config_dir: File.dirname(path))
        begin
          data = YAML.parse(File.read(path)).as_h?
        rescue ex : YAML::ParseException
          STDERR.puts "krikri-lint: invalid config #{path}: #{ex.message}"
          exit 3
        end
        return config unless data
        if (v = data["exclude_paths"]?) && v.as_a?
          config = LintConfig.new(config.skip_list, config.warn_list,
            config.enable_list, config.tags,
            v.as_a.map(&.as_s), config.profile, config.config_dir,
            config.file_warn_list)
        end
        if (v = data["skip_list"]?) && v.as_a?
          config = LintConfig.new(v.as_a.map(&.as_s), config.warn_list,
            config.enable_list, config.tags, config.exclude_paths,
            config.profile, config.config_dir, config.file_warn_list)
        end
        if (v = data["warn_list"]?) && v.as_a?
          list = v.as_a.map(&.as_s)
          config = LintConfig.new(config.skip_list, list,
            config.enable_list, config.tags, config.exclude_paths,
            config.profile, config.config_dir, list)
        end
        if (v = data["profile"]?) && v.as_s?
          config = LintConfig.new(config.skip_list, config.warn_list,
            config.enable_list, config.tags, config.exclude_paths,
            v.as_s, config.config_dir, config.file_warn_list)
        end
        config
      end
    end
  end
end
