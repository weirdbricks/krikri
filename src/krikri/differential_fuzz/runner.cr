require "json"
require "../variable_substitutor"

module Krikri::DifferentialFuzz
  enum Status
    Agree
    BothErrored
    OneErrored
    Mismatch
  end

  class Outcome
    getter expr : String, status : Status
    getter hand_value : String?, jinja_value : String?
    getter hand_error : String?, jinja_error : String?
    getter known_name : String?

    def initialize(@expr : String, @status : Status, @hand_value : String? = nil,
                   @jinja_value : String? = nil, @hand_error : String? = nil,
                   @jinja_error : String? = nil, @known_name : String? = nil)
    end

    def error_class(text : String?) : String
      text ? text.split(":").first? || text : "-"
    end

    # A shrink-friendly identity of the disagreement: error CLASS only
    # (messages embed the expression text, which changes as the tree
    # shrinks), plus the exact rendered pair for a value mismatch.
    def signature : String
      case status
      when .both_errored?
        "botherr|#{error_class(hand_error)}|#{error_class(jinja_error)}"
      when .one_errored?
        "oneerr|#{error_class(hand_error)}|#{error_class(jinja_error)}"
      when .mismatch?
        "mis|#{hand_value}|#{jinja_value}"
      else
        "ok"
      end
    end

    def disagreement? : Bool
      status.one_errored? || status.mismatch?
    end

    def describe(io : IO) : Nil
      io << "expression: " << expr << '\n'
      io << "kind:       " << status
      io << " [known: " << known_name << ']' if known_name
      io << '\n'
      io << "hand-rolled: " << (hand_error || hand_value) << '\n'
      io << "krikri-jinja: " << (jinja_error || jinja_value) << '\n'
    end
  end

  # Runs the SAME generated expression through both evaluators and
  # compares them at the JSON-compact string level:
  #
  # - hand-rolled side: `ExpressionEvaluator#evaluate` (the entry point
  #   `VarSubstitutor#substitute` uses for a plain `{{ }}` span; lenient,
  #   "undefined" sentinel).
  # - krikri-jinja side: `JinjaRenderer#evaluate_value!` (the delegation
  #   target, raw structured JSON::Any) rendered through the SAME
  #   `VariableLookup#format_value` convention the hand-rolled side uses
  #   for its own structured results, so container/bool/float spellings
  #   are compared under one convention instead of flooding on format.
  #
  # Agreement: identical strings, OR both sides parse as numbers and are
  # numerically equal (int-vs-float spellings like "3" vs "3.0" are
  # formatting, not semantics). Both sides raising on the same input is
  # agreement on invalid input. One side raising while the other returns
  # a value, or differing values, is a disagreement - either a real bug
  # or a documented deliberate limit, for the caller to classify.
  class Runner
    # Disagreement shapes already triaged against real Jinja2 3.1.6 and
    # this codebase's own conventions, reported as known differences
    # instead of findings. Each predicate is kept as tight as the class it
    # describes so a NEW divergence in the same neighborhood still
    # surfaces; the unfiltered strict view is always available via
    # `bin/differential_fuzz` output. Details live in KNOWN_MISSING.md's
    # differential-harness entry.
    private record KnownDifference, name : String, matches : Proc(Outcome, Bool)

    KNOWN_DIFFERENCES = [
      # A ternary whose chosen branch is undefined: the krikri-jinja
      # RENDER finalization turns the chainable Undefined into "" while
      # evaluate_value! maps it to the "undefined" sentinel. Real Ansible
      # (StrictUndefined) fails the task in both shapes; this is an
      # internal-consistency gap between the two entry points.
      KnownDifference.new("undefined-ternary-sentinel", ->(o : Outcome) {
        o.status.mismatch? && o.hand_value == "" && o.jinja_value == "undefined"
      }),
      # The hand-rolled evaluator answers (leniently) expressions that
      # are invalid Jinja - bad syntax like `a != not b`, or type-mismatched
      # operations like `dict <= 6.6` - where krikri-jinja raises the same
      # errors real Jinja2 raises. Real Ansible fails these tasks.
      KnownDifference.new("hand-lenient-invalid-input", ->(o : Outcome) {
        o.status.one_errored? && !o.hand_value.nil? && !o.jinja_error.nil?
      }),
      # Index out of range on a list (or into a missing value): the
      # hand-rolled side hard-fails like real Ansible, while
      # evaluate_value!'s nil convention renders the lenient "undefined"
      # sentinel. The strict side matches real Ansible.
      KnownDifference.new("hand-strict-index-oob", ->(o : Outcome) {
        o.status.one_errored? && (o.hand_error || "").includes?("UndefinedVariableError") &&
        o.jinja_value == "undefined" && o.expr.includes?("[")
      }),
    ]

    getter vars : Hash(String, JSON::Any)

    # When false, triaged known differences are reported as findings too
    # (the unfiltered strict view).
    property? classify_known_differences : Bool = true

    def initialize(@vars : Hash(String, JSON::Any) = Fixtures.build)
      @evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(@vars)
      @renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(@vars)
      @lookup = Krikri::VariableSubstitutor::VariableLookup.new(@vars)
    end

    def run(expr : String) : Outcome
      hand_value : String? = nil
      hand_error : String? = nil
      jinja_value : String? = nil
      jinja_error : String? = nil
      begin
        hand_value = @evaluator.evaluate(expr)
      rescue e
        hand_error = "#{e.class.name}: #{e.message}"
      end
      begin
        value = @renderer.evaluate_value!(expr)
        jinja_value = value ? @lookup.format_value(value) : "undefined"
      rescue e
        jinja_error = "#{e.class.name}: #{e.message}"
      end
      status = classify(hand_value, hand_error, jinja_value, jinja_error)
      outcome = Outcome.new(expr, status, hand_value, jinja_value, hand_error, jinja_error)
      if outcome.disagreement? && classify_known_differences? && (known = known_difference(outcome))
        Outcome.new(expr, status, hand_value, jinja_value, hand_error, jinja_error, known)
      else
        outcome
      end
    end

    private def known_difference(outcome : Outcome) : String?
      KNOWN_DIFFERENCES.find(&.matches.call(outcome)).try(&.name)
    end

    private def classify(hand_value : String?, hand_error : String?, jinja_value : String?, jinja_error : String?) : Status
      if hand_error && jinja_error
        Status::BothErrored
      elsif hand_error || jinja_error
        Status::OneErrored
      elsif agree?(hand_value || "", jinja_value || "")
        Status::Agree
      else
        Status::Mismatch
      end
    end

    private def agree?(hand : String, jinja : String) : Bool
      return true if normalize(hand) == normalize(jinja)
      hand_f = hand.to_f?
      jinja_f = jinja.to_f?
      !hand_f.nil? && !jinja_f.nil? && hand_f == jinja_f
    end

    # Object addresses in leaked reprs (a lazy generator rendered into
    # text, e.g. `list | unique ~ 'x'`) differ run to run; the leak itself
    # is identical on both sides, so addresses are not semantic.
    private def normalize(text : String) : String
      text.gsub(/0x[0-9a-f]+/, "0xX")
    end
  end

  # Greedy subtree shrinker: repeatedly tries collapsing each subtree to
  # one of its direct children or a minimal literal, keeping any change
  # that reproduces the SAME disagreement signature. Bounded trials so a
  # stubborn case can't spin.
  class Shrinker
    MINIMAL_LITERALS = [
      Literal.new(JSON::Any.new(0_i64)),
      Literal.new(JSON::Any.new(1_i64)),
      Literal.new(JSON::Any.new("x")),
      Literal.new(JSON::Any.new(true)),
      Literal.new(JSON::Any.new(nil)),
    ] of Node

    def initialize(@runner : Runner, @max_trials : Int32 = 600)
    end

    def shrink(node : Node, signature : String) : Node
      current = node
      trials = 0
      loop do
        replacement = find_reduction(current, signature, trials)
        break if replacement.nil?
        current = replacement
        trials += 1
        break if trials >= @max_trials
      end
      current
    end

    private def find_reduction(current : Node, signature : String, trials : Int32) : Node?
      return nil if trials >= @max_trials
      targets = [] of Node
      current.each_node { |subtree| targets << subtree }
      targets.each do |target|
        candidates = target.children.map { |child| child.as Node } + MINIMAL_LITERALS
        candidates.each do |candidate|
          trial = current.replace(target, candidate)
          next if trial.to_expr == current.to_expr
          outcome = @runner.run(trial.to_expr)
          return trial if outcome.signature == signature
          trials += 1
          return nil if trials >= @max_trials
        end
      end
      nil
    end
  end
end
