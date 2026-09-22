# krikri-lint - static analysis for Ansible playbooks and roles
# Main CLI entry point.

require "option_parser"
require "colorize"
require "./src/krikri/version"
require "./src/krikri_lint/lint"

module Krikri::Lint
  extend self

  def unknown_fix_tags(registry : RuleRegistry, write_list : Array(String)) : String?
    acceptable = Set.new(registry.rules.flat_map(&.tags) +
                         registry.rules.map(&.id) + ["all", "none"])
    unknown = write_list.reject { |tag| acceptable.includes?(tag) }
    unknown.join(", ") unless unknown.empty?
  end

  def main(argv)
    targets = [] of String
    parseable = false
    nocolor = false
    force_color = false
    list_rules = false
    list_profiles = false
    list_tags = false
    show_version = false
    format = "brief"
    quiet = false
    verbose = 0
    cli_profile : String? = nil
    cli_config_file : String? = nil
    cli_skip = [] of String
    cli_warn = [] of String
    cli_enable = [] of String
    cli_tags = [] of String
    cli_fix : Array(String)? = nil

    OptionParser.parse(argv) do |parser|
      parser.banner = "Usage: krikri-lint [options] TARGET [TARGET ...]"
      parser.on("-p", "--parseable", "One result per line: path:line:col rule-id severity message") do
        parseable = true
      end
      parser.on("--nocolor", "Disable colored output") { nocolor = true }
      parser.on("-L", "--list-rules", "List all rules and exit") { list_rules = true }
      parser.on("-P", "--list-profiles", "List profiles and exit") { list_profiles = true }
      parser.on("-T", "--list-tags", "List tags and the rules they cover, and exit") do
        list_tags = true
      end
      parser.on("-f", "--format FORMAT", "Output format: brief, pep8, quiet, json") do |value|
        format = value
      end
      parser.on("--force-color", "Force colored output even when not a tty") do
        force_color = true
      end
      parser.on("-q", "--quiet", "Only report violations, no summary lines") do
        quiet = true
      end
      parser.on("-v", "--verbose", "Increase verbosity (repeatable)") do
        verbose += 1
      end
      parser.on("--profile PROFILE", "Only run rules in this profile") do |value|
        cli_profile = value
      end
      parser.on("-x", "--skip-list LIST", "Comma-separated rule ids to skip") do |value|
        cli_skip.concat(value.split(',').map(&.strip))
      end
      parser.on("-w", "--warn-list LIST", "Comma-separated rule ids to warn about") do |value|
        cli_warn.concat(value.split(',').map(&.strip))
      end
      parser.on("--enable-list LIST", "Comma-separated rule ids to force-enable") do |value|
        cli_enable.concat(value.split(',').map(&.strip))
      end
      parser.on("-t", "--tags TAGS", "Only run rules matching these tags") do |value|
        cli_tags.concat(value.split(',').map(&.strip))
      end
      parser.on("--fix [RULES]", "Auto-fix violations; optional comma-separated rule ids/tags to limit it ('all' is the default scope, 'none' disables)") do |value|
        if value.nil? || value.empty?
          cli_fix = ["all"]
        else
          cli_fix = value.split(',').map(&.strip).reject(&.empty?)
        end
      end
      parser.on("-c", "--config-file FILE", "Path to .ansible-lint config") do |value|
        cli_config_file = value
      end
      parser.on("--version", "Show version and exit") do
        show_version = true
      end
      parser.on("-h", "--help", "Show help") do
        puts parser
        exit 0
      end
      parser.unknown_args do |arg_list|
        targets.concat(arg_list)
      end
      parser.invalid_option do |flag|
        STDERR.puts "krikri-lint: unrecognized option #{flag}"
        STDERR.puts parser
        exit 2
      end
    end

    if show_version
      puts Krikri.version_info("krikri-lint", KRIKRI_LINT_VERSION,
        "Static analysis for Ansible playbooks and roles (ansible-lint parity target)")
      puts "ansible-lint parity target: #{PARITY_TARGET_ANSIBLE_LINT}"
      exit 0
    end

    registry = RuleRegistry.default

    if list_rules
      registry.rules.each do |rule|
        puts "#{rule.id.ljust(28)} #{rule.severity.to_s.ljust(10)} #{rule.tags.join(",")}"
      end
      exit 0
    end

    if list_profiles
      Profile.list.each { |profile| puts profile }
      exit 0
    end

    if list_tags
      puts "# List of tags and rules they cover"
      tag_rules = Hash(String, Array(String)).new { |hash, tag| hash[tag] = [] of String }
      registry.rules.each do |rule|
        rule.tags.each { |tag| tag_rules[tag] << rule.id }
      end
      tag_rules.each do |tag, ids|
        puts "#{tag}:"
        ids.each { |id| puts "  - #{id}" }
      end
      exit 0
    end

    if targets.empty?
      STDERR.puts "krikri-lint: no targets given"
      STDERR.puts "Usage: krikri-lint [options] TARGET [TARGET ...]"
      exit 2
    end

    config = if file = cli_config_file
               LintConfig.from_file(file)
             else
               LintConfig.discover
             end
    if p = cli_profile
      unless Profile.valid?(p)
        STDERR.puts "krikri-lint: unknown profile: #{p}"
        exit 2
      end
      config = LintConfig.new(config.skip_list, config.warn_list,
        config.enable_list, config.tags, config.exclude_paths, p, config.config_dir)
    end
    config = LintConfig.new(config.skip_list + cli_skip, config.warn_list + cli_warn,
      config.enable_list + cli_enable, config.tags + cli_tags,
      config.exclude_paths, config.profile, config.config_dir)

    if (write_list = cli_fix) && (unknown = unknown_fix_tags(registry, write_list))
      STDERR.puts "krikri-lint: Found invalid value(s) (#{unknown}) for --fix arguments, must be one of: all, none, #{(registry.rules.flat_map(&.tags) + registry.rules.map(&.id)).uniq.join(", ")}"
      exit 3
    end

    files = FileDiscovery.discover(targets)

    runner = Runner.new(registry, config)
    violations = begin
      runner.run(files)
    rescue ex
      STDERR.puts "krikri-lint: internal error: #{ex.message}"
      exit 3
    end

    if write_list = cli_fix
      begin
        changed = Fixer.new(registry, write_list).apply(violations)
        if changed.present?
          # Re-report from the fixed files so the output reflects the
          # post-fix state (fixed matches disappear; anything resolved
          # incidentally by another rule's fix disappears too).
          changed_set = Set.new(changed)
          unchanged = violations.reject { |v| changed_set.includes?(v.path) }
          violations = unchanged + runner.run(changed)
        end
      rescue ex
        STDERR.puts "krikri-lint: internal error: #{ex.message}"
        exit 3
      end
    end

    violations.sort_by! { |v| {v.path, v.line, v.column} }

    failures = violations.reject(&.warning?)
    if failures.empty?
      exit 0
    end

    use_color = !nocolor && (force_color || STDOUT.tty?)

    case
    when format == "json"
      puts Violation.to_json(violations)
    else
      violations.each do |v|
        if parseable
          puts "#{v.path}:#{v.line}:#{v.column} #{v.rule_id} #{v.severity.to_s.downcase} #{v.message}"
        elsif use_color
          puts "#{v.path}:#{v.line}: #{v.rule_id.colorize(:yellow)}: #{v.message}"
        else
          puts "#{v.path}:#{v.line}: #{v.rule_id}: #{v.message}"
        end
      end
      unless parseable || quiet
        puts "Read documentation for instructions on how to ignore specific rule violations."
      end
    end
    exit 2
  end
end

Krikri::Lint.main(ARGV)
