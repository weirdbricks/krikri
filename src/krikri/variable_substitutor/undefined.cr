require "json"

module Krikri
  module VariableSubstitutor
    # The engine's real undefined marker - a distinct TYPE, deliberately
    # not a String. The hand-rolled evaluator's historical representation
    # of "this reference has no value" is the literal text "undefined"
    # (120+ production sites), which any real stored value can collide
    # with: `command: printf 'undefined'` + `register: s2`, then
    # `{{ s2.stdout_lines.0 }}` - real Ansible renders the string; a
    # strict-undefined check that re-reads the evaluator's own rendered
    # output cannot tell a genuine miss from that collision and failed
    # the task with "'s2.stdout_lines.0' is undefined" (juju4.pocketid,
    # round 60151; see KNOWN_MISSING.md's dotted-index entry).
    #
    # New code threads THIS type through the seam instead: it is
    # produced only by an actual miss decision (never by a lookup that
    # succeeded), it is never `==` to any String, and its `to_s` renders
    # the same lenient "undefined" text the string sentinel always has,
    # so materializing it at a String boundary is behavior-preserving.
    class Undefined
      INSTANCE = new

      private def initialize
      end

      def to_s(io : IO) : Nil
        io << "undefined"
      end
    end
  end
end
