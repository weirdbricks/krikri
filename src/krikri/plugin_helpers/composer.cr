module Krikri
  module PluginHelpers
    # Pure pieces of community.general.composer's control flow, split out
    # of plugins/composer.cr so the wording/shape choices can be unit
    # tested without a php/composer install.
    module Composer
      extend self

      # has_changed()'s "nothing to do" markers, in the module's own
      # order: composer 1 and composer 2 word the no-op differently.
      NO_CHANGE_MARKERS = ["Nothing to install or update", "Nothing to install, update or remove"]

      # Options the module always appends when the composer command's own
      # help output advertises them (composer >= 1 only; an old composer
      # lacking --no-progress must not be handed it).
      DEFAULT_OPTIONS = %w[no-ansi no-interaction no-progress]

      # argument_spec param => composer option name, in the module's own
      # dict order. `apcu_autoloader` maps to "acpu-autoloader" - the
      # module's own typo, kept verbatim: real composer's option is
      # --apcu-autoloader, so the availability lookup never matches and
      # apcu_autoloader=true silently adds no flag on real Ansible either.
      OPTION_PARAMS = {
        "prefer_source"          => "prefer-source",
        "prefer_dist"            => "prefer-dist",
        "no_dev"                 => "no-dev",
        "no_scripts"             => "no-scripts",
        "no_plugins"             => "no-plugins",
        "apcu_autoloader"        => "acpu-autoloader",
        "optimize_autoloader"    => "optimize-autoloader",
        "classmap_authoritative" => "classmap-authoritative",
        "ignore_platform_reqs"   => "ignore-platform-reqs",
      }

      # Params whose argument_spec default is True (the rest default to
      # False), i.e. the ones that add their option unless the task
      # explicitly disables them.
      PARAMS_DEFAULT_TRUE = %w[no_dev optimize_autoloader]

      # parse_out(): collapse every whitespace run to one space, then
      # strip. Applied to both the msg and the changed-detection text.
      def parse_out(text : String) : String
        text.gsub(/\s+/, " ").strip
      end

      # has_changed(): any "nothing to do" marker present means unchanged.
      def changed?(output : String) : Bool
        NO_CHANGE_MARKERS.all? { |marker| !output.includes?(marker) }
      end

      def param_default_true?(param : String) : Bool
        PARAMS_DEFAULT_TRUE.includes?(param)
      end

      # The --working-dir pair composer_command() appends for a non-global
      # run (a global run passes "global" as a subcommand instead).
      def working_dir_options(working_dir : String) : Array(String)
        ["--working-dir", working_dir]
      end
    end
  end
end
