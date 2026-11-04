module Krikri
  # A Jinja expression that is nothing but container access on a base
  # variable: `base`, `base.key`, `base["key"]`, `base[0]`, `base[expr]`,
  # chained in any order. ansible-core 2.19 tags every YAML-sourced scalar
  # with its defining source position, and those tags SURVIVE plain
  # container access - the templated result of a pure chain still carries
  # the FINAL accessed scalar's origin. Anything that DERIVES a new value
  # (`| upper`, `~`, arithmetic, a filter chain) drops the tag, and real
  # falls back to the templating site's own position (live-verified vs
  # 2.19.11: all three shapes probed for an include_role role-name that
  # fails role resolution - see TaskExecutor#templated_value_lineage_origin).
  class ValueOriginChain
    # :key = mapping-key access, :index = sequence-index access, :dynamic
    # = a subscript whose key must be evaluated at runtime (its own origin
    # is irrelevant - the mapped value's tag is what survives).
    record Step, kind : Symbol, text : String

    getter base : String
    getter steps : Array(Step)

    def initialize(@base : String, @steps : Array(Step))
    end

    # nil when *expr* is not a pure access chain - the caller then keeps
    # the templating site's own Origin instead of guessing one it cannot
    # back with real's behavior.
    def self.parse?(expr : String) : ValueOriginChain?
      chain = Parser.new(expr).parse?
      chain.is_a?(ValueOriginChain) ? chain : nil
    end

    # Cursor over *expr*: one method per chain-piece keeps each branch's
    # decision small (dot step, bracket step, quoted-literal subscript).
    private class Parser
      @s : String
      @i : Int32
      @n : Int32

      def initialize(expr : String)
        @s = expr
        @i = 0
        @n = expr.size
      end

      def parse? : ValueOriginChain?
        skip_whitespace
        return nil unless (base = scan_identifier)
        return nil if base[0].number?

        steps = [] of Step
        loop do
          skip_whitespace
          break if @i >= @n

          case @s[@i]
          when '.'
            return nil unless (step = dot_step?)
            steps << step
          when '['
            return nil unless (step = bracket_step?)
            steps << step
          else
            return nil
          end
        end

        ValueOriginChain.new(base, steps)
      end

      private def skip_whitespace : Nil
        while @i < @n && @s[@i].whitespace?
          @i += 1
        end
      end

      private def scan_identifier : String?
        start = @i
        while @i < @n && (@s[@i].alphanumeric? || @s[@i] == '_')
          @i += 1
        end
        text = @s[start, @i - start]
        text.empty? ? nil : text
      end

      private def dot_step? : Step?
        @i += 1
        skip_whitespace
        return nil unless (attr = scan_identifier)

        if attr =~ /\A\d+\z/
          Step.new(:index, attr)
        else
          Step.new(:key, attr)
        end
      end

      private def bracket_step? : Step?
        open = @i
        @i += 1
        return nil unless (close = scan_closing_bracket)
        inner = @s[(open + 1)...close].strip
        @i = close + 1
        return nil if inner.empty?

        if (key = quoted_key?(inner))
          Step.new(:key, key)
        elsif inner =~ /\A\d+\z/
          Step.new(:index, inner)
        else
          # Any other expression is fine as a SUBSCRIPT - the mapped
          # value's own tag is what survives, not the key's - it just
          # has to be evaluated by the caller.
          Step.new(:dynamic, inner)
        end
      end

      private def scan_closing_bracket : Int32?
        depth = 1
        quote : Char? = nil
        while @i < @n
          char = @s[@i]
          if quote
            quote = nil if char == quote
          elsif char == '"' || char == '\''
            quote = char
          elsif char == '['
            depth += 1
          elsif char == ']'
            depth -= 1
            break if depth == 0
          end
          @i += 1
        end
        depth == 0 ? @i : nil
      end

      private def quoted_key?(inner : String) : String?
        return nil unless inner.size >= 2 &&
                          (inner[0] == '"' || inner[0] == '\'') &&
                          inner[-1] == inner[0] &&
                          !inner.includes?('\\')
        key = inner[1...-1]
        key.empty? ? nil : key
      end
    end
  end
end
