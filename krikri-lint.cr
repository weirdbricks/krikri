# krikri-lint - static analysis for Ansible playbooks and roles
# Main CLI entry point. See krikri-lint.md for the plan.

require "option_parser"
require "colorize"
require "./src/krikri/version"
require "./src/krikri_lint/lint"

module Krikri::Lint
  extend self

  def main(argv)
    targets = [] of String
    parseable = false
    nocolor = false
    list_rules = false
    show_version = false

    OptionParser.parse(argv) do |parser|
      parser.banner = "Usage: krikri-lint [options] TARGET [TARGET ...]"
      parser.on("-p", "--parseable", "One result per line: path:line:col rule-id severity message") do
        parseable = true
      end
      parser.on("--nocolor", "Disable colored output") { nocolor = true }
      parser.on("--list-rules", "List all rules and exit") { list_rules = true }
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
      exit 0
    end

    registry = RuleRegistry.default

    if list_rules
      registry.rules.each do |rule|
        puts "#{rule.id.ljust(28)} #{rule.severity.to_s.ljust(10)} #{rule.tags.join(",")}"
      end
      exit 0
    end

    if targets.empty?
      STDERR.puts "krikri-lint: no targets given"
      STDERR.puts "Usage: krikri-lint [options] TARGET [TARGET ...]"
      exit 2
    end

    files = FileDiscovery.discover(targets)

    violations = begin
      Runner.new(registry).run(files)
    rescue ex
      STDERR.puts "krikri-lint: internal error: #{ex.message}"
      exit 3
    end

    violations.sort_by! { |v| {v.path, v.line, v.column} }

    if violations.empty?
      exit 0
    end

    use_color = !nocolor && STDOUT.tty?
    violations.each do |v|
      if parseable
        puts "#{v.path}:#{v.line}:#{v.column} #{v.rule_id} #{v.severity.to_s.downcase} #{v.message}"
      elsif use_color
        puts "#{v.path}:#{v.line}: #{v.rule_id.colorize(:yellow)}: #{v.message}"
      else
        puts "#{v.path}:#{v.line}: #{v.rule_id}: #{v.message}"
      end
    end
    puts "Read documentation for instructions on how to ignore specific rule violations." unless parseable
    exit 2
  end
end

Krikri::Lint.main(ARGV)
