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

      def initialize(@skip_list = [] of String, @warn_list = [] of String,
                     @enable_list = [] of String, @tags = [] of String,
                     @exclude_paths = [] of String, @profile = "production",
                     @config_dir = ".")
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
            v.as_a.map(&.as_s), config.profile, config.config_dir)
        end
        if (v = data["skip_list"]?) && v.as_a?
          config = LintConfig.new(v.as_a.map(&.as_s), config.warn_list,
            config.enable_list, config.tags, config.exclude_paths,
            config.profile, config.config_dir)
        end
        if (v = data["warn_list"]?) && v.as_a?
          config = LintConfig.new(config.skip_list, v.as_a.map(&.as_s),
            config.enable_list, config.tags, config.exclude_paths,
            config.profile, config.config_dir)
        end
        if (v = data["profile"]?) && v.as_s?
          config = LintConfig.new(config.skip_list, config.warn_list,
            config.enable_list, config.tags, config.exclude_paths,
            v.as_s, config.config_dir)
        end
        config
      end
    end
  end
end
