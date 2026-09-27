require "../spec_helper"
require "../../src/krikri/differential_fuzz/generator"
require "../../src/krikri/differential_fuzz/runner"

# Permanent differential-regression spec for the two coexisting Jinja
# evaluators (see CLAUDE.md): the hand-rolled ExpressionEvaluator and the
# krikri-jinja engine (via JinjaRenderer#evaluate_value!). The full
# exploratory sweep lives in bin/differential_fuzz (--seed/--count/--shrink);
# this spec runs a small fixed-seed slice, fast and deterministic, so any
# future divergence the corpus can reach fails CI immediately.
#
# Disagreements matching Runner::KNOWN_DIFFERENCES (triaged classes,
# documented in KNOWN_MISSING.md) are expected; anything else fails here.
describe Krikri::DifferentialFuzz::Runner do
  it "both evaluators agree on the fixed-seed generated corpus (modulo known differences)" do
    runner = Krikri::DifferentialFuzz::Runner.new
    findings = [] of Krikri::DifferentialFuzz::Outcome

    (1..5).each do |seed|
      generator = Krikri::DifferentialFuzz::Generator.new(Random.new(seed), 4)
      60.times do
        outcome = runner.run(generator.generate.to_expr)
        findings << outcome if outcome.disagreement? && !outcome.known_name
      end
    end

    unless findings.empty?
      puts "Differential fuzz disagreements (seeded corpus):"
      findings.each do |outcome|
        outcome.describe(STDOUT)
        puts "---"
      end
    end
    findings.should be_empty
  end

  it "is deterministic: the same seed generates the same outcome sequence" do
    run_once = -> do
      runner = Krikri::DifferentialFuzz::Runner.new
      generator = Krikri::DifferentialFuzz::Generator.new(Random.new(3), 4)
      60.times.map { runner.run(generator.generate.to_expr).signature }.to_a
    end
    run_once.call.should eq(run_once.call)
  end
end
