# differential_fuzz - differential fuzzing harness: generates Jinja
# expressions and runs each through BOTH evaluators (the hand-rolled
# ExpressionEvaluator and the krikri-jinja engine via JinjaRenderer),
# reporting every disagreement.
#
# CI runs a small fixed-seed slice of this as a permanent regression spec
# (spec/unit/differential_fuzz_spec.cr); use this tool for larger
# exploratory runs, e.g.:
#
#   bin/differential_fuzz --seed 42 --count 5000 --shrink

require "option_parser"
require "colorize"
require "./src/krikri/differential_fuzz/generator"
require "./src/krikri/differential_fuzz/runner"

module Krikri::DifferentialFuzz
  extend self

  def main(argv : Array(String))
    seed = 1
    count = 1000
    max_depth = 4
    shrink = false
    help = false
    expr : String? = nil

    OptionParser.parse(argv) do |parser|
      parser.banner = "Usage: differential_fuzz [options]"
      parser.on("--expr E", "compare a single expression instead of fuzzing") { |v| expr = v }
      parser.on("--seed N", "RNG seed (default 1)") { |v| seed = v.to_i }
      parser.on("--count N", "expressions to generate (default 1000)") { |v| count = v.to_i }
      parser.on("--max-depth N", "expression tree depth budget (default 4)") { |v| max_depth = v.to_i }
      parser.on("--shrink", "minimize each disagreement to a smaller reproducer") { shrink = true }
      parser.on("-h", "--help", "show help") do
        puts parser
        help = true
      end
    end

    return 0 if help

    runner = Runner.new

    if e = expr
      outcome = runner.run(e)
      outcome.describe(STDOUT)
      return outcome.disagreement? && !outcome.known_name ? 1 : 0
    end

    generator = Generator.new(Random.new(seed), max_depth)
    outcomes = [] of Outcome
    nodes = Hash(String, Node).new

    count.times do
      node = generator.generate
      outcome = runner.run(node.to_expr)
      outcomes << outcome
      nodes[outcome.expr] = node if outcome.disagreement?
    end

    findings = outcomes.select(&.disagreement?).reject(&.known_name)
    known = outcomes.compact_map do |o|
      o.known_name if o.disagreement?
    end
    print_summary(outcomes, findings, known, seed, count, max_depth)

    if shrink && !findings.empty?
      shrinker = Shrinker.new(runner)
      minimized = Hash(String, Node).new
      findings.each do |outcome|
        next if minimized.has_key?(outcome.signature)
        node = nodes[outcome.expr]?
        minimized[outcome.signature] = shrinker.shrink(node, outcome.signature) if node
      end
      puts "minimized reproducers:".colorize(:yellow)
      minimized.each do |signature, node|
        puts "  #{signature} -> #{node.to_expr}".colorize(:yellow)
      end
    end

    findings.empty? ? 0 : 1
  end

  def print_summary(outcomes : Array(Outcome), findings : Array(Outcome), known : Array(String), seed : Int32, count : Int32, max_depth : Int32) : Nil
    puts "seed=#{seed} count=#{count} max_depth=#{max_depth}"
    puts "agree:        #{outcomes.count(&.status.agree?)}"
    both = outcomes.select(&.status.both_errored?)
    puts "both-errored: #{both.size} (agreement on invalid input)"
    both.group_by { |o| "#{o.error_class(o.hand_error)} / #{o.error_class(o.jinja_error)}" }.each do |pair, group|
      puts "  #{pair}: #{group.size}"
    end
    puts "one-errored:  #{outcomes.count(&.status.one_errored?)}"
    puts "mismatch:     #{outcomes.count(&.status.mismatch?)}"
    puts "known diffs:  #{known.size} (#{known.tally.map { |name, n| "#{name}: #{n}" }.join(", ")})"

    if findings.empty?
      puts "NO UNCLASSIFIED DISAGREEMENTS".colorize(:green)
    else
      puts "UNCLASSIFIED DISAGREEMENTS: #{findings.size}".colorize(:red)
      findings.each do |outcome|
        outcome.describe(STDOUT)
        puts "---"
      end
    end
  end
end

exit(Krikri::DifferentialFuzz.main(ARGV))
