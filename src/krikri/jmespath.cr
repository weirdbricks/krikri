require "json"

module Krikri
  # A JMESPath query engine backing the `json_query` filter (real
  # Ansible's own filter from `community.general`, commonly reachable as
  # a bare name). Implemented here rather than vendored: the Crystal
  # ecosystem has no maintained JMESPath shard, so this is a from-scratch
  # recursive-descent parser + evaluator over JSON::Any.
  #
  # Supported grammar (per the JMESPath specification):
  # - field access (`foo`, `foo.bar`, quoted `"a-b"`)
  # - the current node `@` and JSON literals in backticks (`` `42` ``)
  # - index `[0]` (negative ok) and slices `[1:10:2]`
  # - wildcards `[*]`/`.*`, list flattening `[]`, filters `[?expr]`
  # - multi-select lists `[a, b]` and hashes `{k: v}`
  # - pipe `|`, and/or/not (`&&`, `||`, `!`), comparisons
  #   (`==`, `!=`, `<`, `<=`, `>`, `>=`)
  # - expression references `&expr` for the by/map functions
  # - functions: length, keys, values, type, not_null, to_string,
  #   to_number, to_array, abs, ceil, floor, avg, sum, min, max, min_by,
  #   max_by, sort, sort_by, reverse, join, contains, starts_with,
  #   ends_with, map, merge
  #
  # Projection semantics follow the spec's observable behavior: a
  # wildcard/flatten/filter produces a projection, and a field access /
  # index / slice applied to a projection maps over its elements, dropping
  # `null` results. Syntactically invalid expressions raise
  # `JMESPath::Error` (real Ansible's json_query fails the task on an
  # unparseable expression too).
  module JMESPath
    class Error < Exception; end

    NULL = JSON::Any.new(nil)

    # Applies a JMESPath expression to *data*, returning the result.
    def self.evaluate(expression : String, data : JSON::Any) : JSON::Any
      tokens = Tokenizer.new(expression).tokenize
      parser = Parser.new(tokens, expression)
      ast = parser.parse_expression
      parser.expect_end
      Evaluator.new.eval(ast, data)
    end

    # ------------------------------------------------------------------
    # Tokenizer
    # ------------------------------------------------------------------
    enum TokenKind
      Identifier; QuotedIdent; StringLit; RawLit; Number
      Dot; Star; LBracket; RBracket; LBrace; RBrace; LParen; RParen
      Pipe; PipePipe; Comma; Colon; At; Bang; Amp; Question; Lt; Gt; Le; Ge; Eq; Ne; AndAnd
      Eof
    end

    struct Token
      getter kind : TokenKind
      getter text : String

      def initialize(@kind : TokenKind, @text : String); end
    end

    class Tokenizer
      def initialize(@input : String); end

      def tokenize : Array(Token)
        tokens = [] of Token
        chars = @input.chars
        i = 0
        while i < chars.size
          char = chars[i]
          case char
          when .whitespace? then i += 1
          when '.'          then tokens << Token.new(TokenKind::Dot, "."); i += 1
          when '*'          then tokens << Token.new(TokenKind::Star, "*"); i += 1
          when '['          then tokens << Token.new(TokenKind::LBracket, "["); i += 1
          when ']'          then tokens << Token.new(TokenKind::RBracket, "]"); i += 1
          when '{'          then tokens << Token.new(TokenKind::LBrace, "{"); i += 1
          when '}'          then tokens << Token.new(TokenKind::RBrace, "}"); i += 1
          when '('          then tokens << Token.new(TokenKind::LParen, "("); i += 1
          when ')'          then tokens << Token.new(TokenKind::RParen, ")"); i += 1
          when ','          then tokens << Token.new(TokenKind::Comma, ","); i += 1
          when ':'          then tokens << Token.new(TokenKind::Colon, ":"); i += 1
          when '@'          then tokens << Token.new(TokenKind::At, "@"); i += 1
          when '?'          then tokens << Token.new(TokenKind::Question, "?"); i += 1
          when '<'
            if i + 1 < chars.size && chars[i + 1] == '='
              tokens << Token.new(TokenKind::Le, "<="); i += 2
            else
              tokens << Token.new(TokenKind::Lt, "<"); i += 1
            end
          when '>'
            if i + 1 < chars.size && chars[i + 1] == '='
              tokens << Token.new(TokenKind::Ge, ">="); i += 2
            else
              tokens << Token.new(TokenKind::Gt, ">"); i += 1
            end
          when '!'
            if i + 1 < chars.size && chars[i + 1] == '='
              tokens << Token.new(TokenKind::Ne, "!="); i += 2
            else
              tokens << Token.new(TokenKind::Bang, "!"); i += 1
            end
          when '='
            if i + 1 < chars.size && chars[i + 1] == '='
              tokens << Token.new(TokenKind::Eq, "=="); i += 2
            else
              raise Error.new("Invalid jmespath expression: unexpected single '=' at #{i}")
            end
          when '|'
            if i + 1 < chars.size && chars[i + 1] == '|'
              tokens << Token.new(TokenKind::PipePipe, "||"); i += 2
            else
              tokens << Token.new(TokenKind::Pipe, "|"); i += 1
            end
          when '&'
            if i + 1 < chars.size && chars[i + 1] == '&'
              tokens << Token.new(TokenKind::AndAnd, "&&"); i += 2
            else
              tokens << Token.new(TokenKind::Amp, "&"); i += 1
            end
          when '\'', '"'
            string, next_i = read_quoted(chars, i)
            # jmespath.py semantics: single-quoted is a STRING LITERAL
            # (`contains(@, 'ell')`), double-quoted is a QUOTED
            # IDENTIFIER (`"weird-key"` names a field) - different token
            # kinds, different parse results.
            tokens << Token.new(char == '\'' ? TokenKind::StringLit : TokenKind::QuotedIdent, string)
            i = next_i
          when '`'
            raw, next_i = read_raw(chars, i)
            tokens << Token.new(TokenKind::RawLit, raw)
            i = next_i
          when '-', '0'..'9'
            number, next_i = read_number(chars, i)
            tokens << Token.new(TokenKind::Number, number)
            i = next_i
          else
            if char.ascii_letter? || char == '_'
              start = i
              while i < chars.size && (chars[i].ascii_alphanumeric? || chars[i] == '_')
                i += 1
              end
              tokens << Token.new(TokenKind::Identifier, chars[start...i].join)
            else
              raise Error.new("Invalid jmespath expression: unexpected character '#{char}' at #{i}")
            end
          end
        end
        tokens << Token.new(TokenKind::Eof, "")
        tokens
      end

      private def read_quoted(chars, start) : {String, Int32}
        quote = chars[start]
        i = start + 1
        result = String::Builder.new
        while i < chars.size && chars[i] != quote
          if chars[i] == '\\' && i + 1 < chars.size
            result << chars[i + 1]
            i += 2
          else
            result << chars[i]
            i += 1
          end
        end
        raise Error.new("Invalid jmespath expression: unterminated string") if i >= chars.size
        {result.to_s, i + 1}
      end

      private def read_raw(chars, start) : {String, Int32}
        i = start + 1
        result = String::Builder.new
        while i < chars.size && chars[i] != '`'
          result << chars[i]
          i += 1
        end
        raise Error.new("Invalid jmespath expression: unterminated raw literal") if i >= chars.size
        {result.to_s.strip, i + 1}
      end

      private def read_number(chars, start) : {String, Int32}
        i = start
        i += 1 if chars[i] == '-'
        while i < chars.size && (chars[i].ascii_number? || chars[i] == '.')
          i += 1
        end
        {chars[start...i].join, i}
      end
    end

    # ------------------------------------------------------------------
    # AST
    # ------------------------------------------------------------------
    abstract class Node; end

    class Current < Node; end

    class Field < Node
      getter name : String

      def initialize(@name : String); end
    end

    class Literal < Node
      getter value : JSON::Any

      def initialize(@value : JSON::Any); end
    end

    class SubExpression < Node
      getter left : Node, right : Node

      def initialize(@left : Node, @right : Node); end
    end

    class Index < Node
      getter left : Node, index : Int64

      def initialize(@left : Node, @index : Int64); end
    end

    class Slice < Node
      getter left : Node, start : Int64?, stop : Int64?, step : Int64

      def initialize(@left : Node, @start : Int64?, @stop : Int64?, @step : Int64); end
    end

    class Wildcard < Node
      getter left : Node?

      def initialize(@left : Node?); end
    end

    class Flatten < Node
      getter left : Node

      def initialize(@left : Node); end
    end

    class Filter < Node
      getter left : Node, condition : Node

      def initialize(@left : Node, @condition : Node); end
    end

    class MultiSelectList < Node
      getter left : Node?, items : Array(Node)

      def initialize(@left : Node?, @items : Array(Node)); end
    end

    class MultiSelectHash < Node
      getter left : Node?, entries : Array(Tuple(String, Node))

      def initialize(@left : Node?, @entries : Array(Tuple(String, Node))); end
    end

    class Pipe < Node
      getter left : Node, right : Node

      def initialize(@left : Node, @right : Node); end
    end

    class FunctionCall < Node
      getter name : String, args : Array(Node)

      def initialize(@name : String, @args : Array(Node)); end
    end

    class Comparison < Node
      getter op : String, left : Node, right : Node

      def initialize(@op : String, @left : Node, @right : Node); end
    end

    class AndOp < Node
      getter left : Node, right : Node

      def initialize(@left : Node, @right : Node); end
    end

    class OrOp < Node
      getter left : Node, right : Node

      def initialize(@left : Node, @right : Node); end
    end

    class NotOp < Node
      getter expr : Node

      def initialize(@expr : Node); end
    end

    class ExpRef < Node
      getter expr : Node

      def initialize(@expr : Node); end
    end

    # ------------------------------------------------------------------
    # Parser - recursive descent over the token stream, precedence per
    # the JMESPath grammar (pipe lowest, then or, then and, then unary).
    # ------------------------------------------------------------------
    class Parser
      def initialize(@tokens : Array(Token), @source : String); end

      getter tokens

      def parse_expression : Node
        parse_pipe
      end

      def expect_end : Nil
        unless peek.kind == TokenKind::Eof
          raise Error.new("Invalid jmespath expression: unexpected token '#{peek.text}' in #{@source.inspect}")
        end
      end

      private def peek : Token
        @tokens[0]
      end

      private def advance : Token
        token = @tokens.shift
        token
      end

      private def accept(kind : TokenKind) : Token?
        return nil unless peek.kind == kind
        advance
      end

      private def expect(kind : TokenKind, what : String) : Token
        token = peek
        unless token.kind == kind
          raise Error.new("Invalid jmespath expression: expected #{what}, got '#{token.text || token.kind}' in #{@source.inspect}")
        end
        advance
        token
      end

      private def parse_pipe : Node
        left = parse_or
        while accept(TokenKind::Pipe)
          left = Pipe.new(left, parse_or)
        end
        left
      end

      private def parse_or : Node
        left = parse_and
        while accept(TokenKind::PipePipe)
          left = OrOp.new(left, parse_and)
        end
        left
      end

      private def parse_and : Node
        left = parse_comparison
        while accept(TokenKind::AndAnd)
          left = AndOp.new(left, parse_comparison)
        end
        left
      end

      # Comparison operators bind tighter than &&/|| but looser than
      # field/pipe chains - `a.b == `1` && c < `2`` groups as
      # `((a.b == `1`) && (c < `2`))`.
      private def parse_comparison : Node
        left = parse_unary
        op = peek_comparison_op
        return left unless op

        advance
        Comparison.new(op, left, parse_unary)
      end

      private def peek_comparison_op : String?
        case peek.kind
        when TokenKind::Eq then "=="
        when TokenKind::Ne then "!="
        when TokenKind::Lt then "<"
        when TokenKind::Le then "<="
        when TokenKind::Gt then ">"
        when TokenKind::Ge then ">="
        end
      end

      private def parse_unary : Node
        if accept(TokenKind::Bang)
          return NotOp.new(parse_unary)
        end
        if accept(TokenKind::Amp)
          return ExpRef.new(parse_chain)
        end
        parse_chain
      end

      private def parse_chain : Node
        node = parse_primary
        loop do
          if accept(TokenKind::Dot)
            if accept(TokenKind::Star)
              node = Wildcard.new(node)
            else
              token = expect_ident_or_string("field name after '.'")
              node = SubExpression.new(node, Field.new(token.text))
            end
          elsif peek.kind == TokenKind::LBracket
            node = parse_bracket(node)
          else
            break
          end
        end
        node
      end

      private def parse_primary : Node
        case peek.kind
        when TokenKind::At
          advance
          Current.new
        when TokenKind::Star
          advance
          Wildcard.new(nil)
        when TokenKind::RawLit
          Literal.new(parse_raw_literal(advance.text))
        when TokenKind::LParen
          advance
          node = parse_expression
          expect(TokenKind::RParen, "')'")
          node
        when TokenKind::LBracket
          # Expression-initial '[': a multi-select list when it has
          # comma-separated items, but an index/slice directly on the
          # current node when it holds a single number (`[1]`, `[:2]`).
          # `[]`/`[*]`/`[?...]` at expression start are the wildcard,
          # flatten and filter forms applied to the current node.
          advance
          case peek.kind
          when TokenKind::RBracket
            advance
            return Flatten.new(Current.new)
          when TokenKind::Star
            advance
            expect(TokenKind::RBracket, "']'")
            return Wildcard.new(Current.new)
          when TokenKind::Question
            advance
            condition = parse_expression
            expect(TokenKind::RBracket, "']'")
            return Filter.new(Current.new, condition)
          when TokenKind::Number, TokenKind::Colon
            return parse_slice_or_index(Current.new)
          else
            # fall through to the multi-select list below
          end
          items = [parse_expression]
          while accept(TokenKind::Comma)
            items << parse_expression
          end
          expect(TokenKind::RBracket, "']'")
          MultiSelectList.new(nil, items)
        when TokenKind::LBrace
          advance
          entries = [] of Tuple(String, Node)
          loop do
            key_token = expect_ident_or_string("hash key")
            expect(TokenKind::Colon, "':'")
            entries << {key_token.text, parse_expression}
            break unless accept(TokenKind::Comma)
          end
          expect(TokenKind::RBrace, "'}'")
          MultiSelectHash.new(nil, entries)
        when TokenKind::Identifier
          name = advance.text
          if peek.kind == TokenKind::LParen
            advance
            args = [] of Node
            unless peek.kind == TokenKind::RParen
              args << parse_expression
              while accept(TokenKind::Comma)
                args << parse_expression
              end
            end
            expect(TokenKind::RParen, "')'")
            FunctionCall.new(name, args)
          else
            Field.new(name)
          end
        when TokenKind::StringLit
          # Single-quoted in expression position: a string LITERAL
          # (jmespath.py's `literal` token). Double-quoted is a quoted
          # IDENTIFIER (below) - the two tokenize differently.
          Literal.new(JSON::Any.new(advance.text))
        when TokenKind::QuotedIdent
          Field.new(advance.text)
        when TokenKind::Number
          Literal.new(JSON.parse(advance.text))
        else
          raise Error.new("Invalid jmespath expression: unexpected token '#{peek.text}' in #{@source.inspect}")
        end
      end

      # Parses everything a postfix `[` can introduce.
      private def parse_bracket(left : Node) : Node
        expect(TokenKind::LBracket, "'['")
        case peek.kind
        when TokenKind::RBracket
          advance
          Flatten.new(left)
        when TokenKind::Star
          advance
          expect(TokenKind::RBracket, "']'")
          Wildcard.new(left)
        when TokenKind::Question
          advance
          condition = parse_expression
          expect(TokenKind::RBracket, "']'")
          Filter.new(left, condition)
        when TokenKind::Number, TokenKind::Colon
          parse_slice_or_index(left)
        else
          items = [parse_expression]
          while accept(TokenKind::Comma)
            items << parse_expression
          end
          expect(TokenKind::RBracket, "']'")
          MultiSelectList.new(left, items)
        end
      end

      private def parse_slice_or_index(left : Node) : Node
        start = nil
        stop = nil
        step : Int64? = nil

        if token = accept(TokenKind::Number)
          start = token.text.to_i64
        end

        if accept(TokenKind::Colon)
          stop = accept(TokenKind::Number).try(&.text.to_i64)
          if accept(TokenKind::Colon)
            step_token = accept(TokenKind::Number)
            raise Error.new("Invalid jmespath expression: slice step is required after second ':'") unless step_token
            step = step_token.text.to_i64
          end
          expect(TokenKind::RBracket, "']'")
          Slice.new(left, start, stop, step || 1i64)
        else
          raise Error.new("Invalid jmespath expression: missing index") unless start
          expect(TokenKind::RBracket, "']'")
          Index.new(left, start)
        end
      end

      private def expect_ident_or_string(what : String) : Token
        case peek.kind
        when TokenKind::Identifier, TokenKind::QuotedIdent
          advance
        else
          raise Error.new("Invalid jmespath expression: expected #{what}, got '#{peek.text}' in #{@source.inspect}")
        end
      end

      private def parse_raw_literal(text : String) : JSON::Any
        JSON.parse(text)
      rescue
        # A raw literal that isn't valid JSON is treated as a string -
        # matches jmespath.py's lenient fallback for `` `bareword` ``.
        JSON.parse(text.to_json)
      end
    end

    # ------------------------------------------------------------------
    # Evaluator - returns (value, is_projection) pairs; a projection is
    # the spec's name for a value produced by a wildcard/flatten/filter,
    # where subsequent sub-expressions map over the elements instead of
    # treating the array as data.
    # ------------------------------------------------------------------
    class Evaluator
      struct Result
        getter value : JSON::Any
        getter? projection : Bool

        def initialize(@value : JSON::Any, @projection : Bool); end
      end

      def eval(node : Node, data : JSON::Any) : JSON::Any
        eval_node(node, data, false).value
      end

      private def eval_node(node : Node, data : JSON::Any, projection : Bool) : Result
        case node
        when Current
          Result.new(data, false)
        when Literal
          Result.new(node.value, false)
        when Field
          eval_field(node.name, data, projection)
        when SubExpression
          left_result = eval_node(node.left, data, projection)
          left = left_result.value
          left_proj = left_result.projection?
          if left_proj
            eval_projection(node.right, left)
          else
            eval_node(node.right, left, false)
          end
        when Index
          base_result = eval_node(node.left, data, projection)
          base = base_result.value
          base_proj = base_result.projection?
          if base_proj
            mapped = base.as_a.compact_map do |element|
              index_value(element, node.index)
            end
            Result.new(JSON::Any.new(mapped), true)
          else
            Result.new(index_value(base, node.index) || NULL, false)
          end
        when Slice
          base_result = eval_node(node.left, data, projection)
          base = base_result.value
          base_proj = base_result.projection?
          if base_proj
            mapped = base.as_a.compact_map do |element|
              slice_value(element, node)
            end
            Result.new(JSON::Any.new(mapped), true)
          else
            Result.new(slice_value(base, node) || NULL, false)
          end
        when Wildcard
          base = if left = node.left
                   eval_node(left, data, projection).value
                 else
                   data
                 end
          case raw = base.raw
          when Hash
            Result.new(JSON::Any.new(raw.values), true)
          when Array
            Result.new(base, true)
          else
            Result.new(NULL, false)
          end
        when Flatten
          base = eval_node(node.left, data, projection).value
          case raw = base.raw
          when Array
            flat = [] of JSON::Any
            raw.each do |element|
              if element.raw.is_a?(Array)
                flat.concat(element.as_a)
              else
                flat << element
              end
            end
            Result.new(JSON::Any.new(flat), true)
          else
            Result.new(NULL, false)
          end
        when Filter
          base = eval_node(node.left, data, projection).value
          case raw = base.raw
          when Array
            kept = raw.select { |element| truthy(eval_node(node.condition, element, false).value) }
            Result.new(JSON::Any.new(kept), true)
          when Hash
            kept = raw.values.select { |element| truthy(eval_node(node.condition, element, false).value) }
            Result.new(JSON::Any.new(kept), true)
          else
            Result.new(NULL, false)
          end
        when MultiSelectList
          if left = node.left
            base_result = eval_node(left, data, projection)
            base = base_result.value
            base_proj = base_result.projection?
            if base_proj
              mapped = base.as_a.map do |element|
                JSON::Any.new(node.items.map { |item| eval_node(item, element, false).value })
              end
              return Result.new(JSON::Any.new(mapped), true)
            end
            data = base
          end
          Result.new(JSON::Any.new(node.items.map { |item| eval_node(item, data, false).value }), false)
        when MultiSelectHash
          if left = node.left
            base_result = eval_node(left, data, projection)
            base = base_result.value
            base_proj = base_result.projection?
            if base_proj
              mapped = base.as_a.map do |element|
                hash = Hash(String, JSON::Any).new
                node.entries.each { |key, item| hash[key] = eval_node(item, element, false).value }
                JSON::Any.new(hash)
              end
              return Result.new(JSON::Any.new(mapped), true)
            end
            data = base
          end
          hash = Hash(String, JSON::Any).new
          node.entries.each { |key, item| hash[key] = eval_node(item, data, false).value }
          Result.new(JSON::Any.new(hash), false)
        when Pipe
          left_value = eval_node(node.left, data, false).value
          eval_node(node.right, left_value, false)
        when Comparison
          left_value = eval_node(node.left, data, projection).value
          right_value = eval_node(node.right, data, projection).value
          Result.new(JSON::Any.new(compare(node.op, left_value, right_value)), false)
        when AndOp
          left_value = eval_node(node.left, data, projection).value
          if truthy(left_value)
            eval_node(node.right, data, projection)
          else
            Result.new(left_value, false)
          end
        when OrOp
          left_value = eval_node(node.left, data, projection).value
          if truthy(left_value)
            Result.new(left_value, false)
          else
            eval_node(node.right, data, projection)
          end
        when NotOp
          value = eval_node(node.expr, data, projection).value
          Result.new(JSON::Any.new(!truthy(value)), false)
        when ExpRef
          # An expression reference only makes sense inside the
          # by/map/sort functions, which receive the node itself - a
          # bare `&expr` anywhere else evaluates to null.
          Result.new(NULL, false)
        when FunctionCall
          call_function(node, data, projection)
        else
          raise Error.new("Invalid jmespath expression: unhandled node #{node.class}")
        end
      end

      private def eval_projection(right : Node, elements : JSON::Any) : Result
        mapped = elements.as_a.compact_map do |element|
          value = eval_node(right, element, false).value
          value.raw.nil? ? nil : value
        end
        Result.new(JSON::Any.new(mapped), true)
      end

      private def eval_field(name : String, data : JSON::Any, projection : Bool) : Result
        case raw = data.raw
        when Hash
          found = raw[name]? || NULL
          Result.new(found, false)
        when Array
          if projection
            eval_projection(Field.new(name), data)
          else
            Result.new(NULL, false)
          end
        else
          Result.new(NULL, false)
        end
      end

      private def index_value(data : JSON::Any, index : Int64) : JSON::Any?
        return nil unless array = data.as_a?
        idx = index < 0 ? array.size + index : index
        return nil if idx < 0 || idx >= array.size
        array[idx]
      end

      private def slice_value(data : JSON::Any, node : Slice) : JSON::Any?
        return nil unless array = data.as_a?
        size = array.size
        step = node.step
        return JSON::Any.new([] of JSON::Any) if step == 0

        if step > 0
          start = (node.start || 0)
          start += size if start < 0
          stop = (node.stop || size)
          stop += size if stop < 0
          start = Math.max(0, start)
          stop = Math.min(size, stop)
          result = [] of JSON::Any
          idx = start
          while idx < stop
            result << array[idx]
            idx += step
          end
          JSON::Any.new(result)
        else
          start = node.start || size - 1
          start += size if start < 0
          # A negative step with no explicit stop walks down to index 0
          # inclusive - the sentinel -1 (outside any adjusted index).
          if s = node.stop
            stop = s < 0 ? s + size : s
          else
            stop = -1
          end
          start = Math.min(size - 1, start)
          result = [] of JSON::Any
          idx = start
          while idx > stop
            result << array[idx] if idx >= 0 && idx < size
            idx += step
          end
          JSON::Any.new(result)
        end
      end

      # JMESPath truthiness: false, null, empty string, empty array and
      # empty hash are falsy; everything else truthy.
      private def truthy(value : JSON::Any) : Bool
        case raw = value.raw
        when Nil, Bool then raw == true
        when String    then !raw.empty?
        when Array     then !raw.empty?
        when Hash      then !raw.empty?
        else                true
        end
      end

      private def compare(op : String, left : JSON::Any, right : JSON::Any) : Bool
        case op
        when "=="
          json_equal?(left, right)
        when "!="
          !json_equal?(left, right)
        else
          ordering = order(left, right)
          case op
          when "<"  then ordering < 0
          when "<=" then ordering <= 0
          when ">"  then ordering > 0
          when ">=" then ordering >= 0
          else           raise Error.new("Invalid jmespath expression: unknown comparison '#{op}'")
          end
        end
      end

      private def json_equal?(left : JSON::Any, right : JSON::Any) : Bool
        # JSON numbers may be Int64 or Float64 for the same value.
        l_num = left.raw
        r_num = right.raw
        if (l_num.is_a?(Int64) || l_num.is_a?(Float64)) && (r_num.is_a?(Int64) || r_num.is_a?(Float64))
          return l_num.to_f == r_num.to_f
        end
        left == right
      end

      private def order(left : JSON::Any, right : JSON::Any) : Int32
        l = left.raw
        r = right.raw
        if l.is_a?(Int64) || l.is_a?(Float64)
          if r.is_a?(Int64) || r.is_a?(Float64)
            x = l.to_f
            y = r.to_f
            return x < y ? -1 : (x > y ? 1 : 0)
          end
        end
        if l.is_a?(String) && r.is_a?(String)
          return l < r ? -1 : (l > r ? 1 : 0)
        end
        raise Error.new("Invalid jmespath expression: cannot order #{describe(l)} and #{describe(r)}")
      end

      private def numeric?(raw) : Bool
        raw.is_a?(Int64) || raw.is_a?(Float64)
      end

      private def describe(raw) : String
        case raw
        when Nil            then "null"
        when Bool           then "boolean"
        when String         then "string"
        when Array          then "array"
        when Hash           then "object"
        when Int64, Float64 then "number"
        else                     raw.class.to_s
        end
      end

      private def call_function(node : FunctionCall, data : JSON::Any, projection : Bool) : Result
        name = node.name

        # The by/map functions take an expression reference (`&expr`),
        # which must NOT be evaluated - it is applied per element. All
        # other arguments evaluate eagerly.
        if {"sort_by", "min_by", "max_by", "map"}.includes?(name)
          return Result.new(by_or_map(name, node, data), false)
        end

        args = node.args.map { |arg| eval_node(arg, data, projection).value }
        value = case name
                when "length"
                  case raw = args[0]?.try(&.raw)
                  when String then JSON::Any.new(raw.size.to_i64)
                  when Array  then JSON::Any.new(raw.size.to_i64)
                  when Hash   then JSON::Any.new(raw.size.to_i64)
                  else             raise Error.new("Invalid jmespath expression: length() requires a string, array or object")
                  end
                when "keys"
                  hash = args[0]?.try(&.as_h?)
                  raise Error.new("Invalid jmespath expression: keys() requires an object") unless hash
                  JSON::Any.new(hash.keys.map { |k| JSON::Any.new(k) })
                when "values"
                  hash = args[0]?.try(&.as_h?)
                  array = args[0]?.try(&.as_a?)
                  if hash
                    JSON::Any.new(hash.values)
                  elsif array
                    JSON::Any.new(array)
                  else
                    raise Error.new("Invalid jmespath expression: values() requires an object or array")
                  end
                when "type"
                  JSON::Any.new(describe(args[0]?.try(&.raw) || nil))
                when "not_null"
                  found = args.find { |arg| !arg.raw.nil? }
                  found || NULL
                when "to_string"
                  raw = args[0]?.try(&.raw)
                  JSON::Any.new(raw.is_a?(String) ? raw : args[0].to_json)
                when "to_number"
                  raw = args[0]?.try(&.raw)
                  case raw
                  when Int64, Float64 then args[0]
                  when String         then (JSON.parse(raw) rescue NULL)
                  else                     NULL
                  end
                when "to_array"
                  JSON::Any.new([args[0]? || NULL])
                when "abs"
                  raw = args[0]?.try(&.raw)
                  if raw.is_a?(Int64)
                    JSON::Any.new(raw.abs)
                  elsif raw.is_a?(Float64)
                    JSON::Any.new(raw.abs)
                  else
                    raise Error.new("Invalid jmespath expression: abs() requires a number")
                  end
                when "ceil"
                  JSON::Any.new(as_number(args[0], "ceil").ceil.to_i64)
                when "floor"
                  JSON::Any.new(as_number(args[0], "floor").floor.to_i64)
                when "avg"
                  array = args[0]?.try(&.as_a?)
                  raise Error.new("Invalid jmespath expression: avg() requires an array") unless array
                  JSON::Any.new(array.sum(0.0) { |item| as_number(item, "avg") } / array.size)
                when "sum"
                  array = args[0]?.try(&.as_a?)
                  raise Error.new("Invalid jmespath expression: sum() requires an array") unless array
                  total = array.sum(0.0) do |item|
                    raw = item.raw
                    raise Error.new("Invalid jmespath expression: sum() requires numbers") unless raw.is_a?(Int64) || raw.is_a?(Float64)
                    raw.is_a?(Int64) ? raw.to_f : raw
                  end
                  JSON::Any.new(total.to_i64 == total ? total.to_i64 : total)
                when "min"
                  sorted_min_max(args[0], "min")
                when "max"
                  sorted_min_max(args[0], "max")
                when "join"
                  array = args[1]?.try(&.as_a?)
                  raise Error.new("Invalid jmespath expression: join() requires a separator and an array") unless array
                  JSON::Any.new(array.map(&.as_s).join(args[0].as_s))
                when "reverse"
                  case raw = args[0]?.try(&.raw)
                  when String then JSON::Any.new(raw.reverse)
                  when Array  then JSON::Any.new(raw.reverse)
                  else             raise Error.new("Invalid jmespath expression: reverse() requires a string or array")
                  end
                when "sort"
                  array = args[0]?.try(&.as_a?)
                  raise Error.new("Invalid jmespath expression: sort() requires an array") unless array
                  JSON::Any.new(sort_array(array))
                when "contains"
                  subject = args[0]?
                  needle = args[1]? || NULL
                  case raw = subject.try(&.raw)
                  when String then JSON::Any.new(raw.includes?(needle.to_s))
                  when Array  then JSON::Any.new(raw.any? { |item| json_equal?(item, needle) })
                  else             raise Error.new("Invalid jmespath expression: contains() requires a string or array")
                  end
                when "starts_with"
                  JSON::Any.new(args[0].as_s.starts_with?(args[1].as_s))
                when "ends_with"
                  JSON::Any.new(args[0].as_s.ends_with?(args[1].as_s))
                when "merge"
                  merged = Hash(String, JSON::Any).new
                  args.each do |arg|
                    if hash = arg.as_h?
                      merged.merge!(hash)
                    end
                  end
                  JSON::Any.new(merged)
                else
                  raise Error.new("Invalid jmespath expression: unknown function '#{name}'")
                end
        Result.new(value, false)
      end

      private def by_or_map(name : String, node : FunctionCall, data : JSON::Any) : JSON::Any
        # map(&expr, list) takes the reference FIRST and evaluates the
        # list argument as an expression; the by/sort_by family takes
        # the list first (the current node's evaluated array), reference
        # second.
        ref_arg = name == "map" ? node.args[0]? : node.args[1]?
        raise Error.new("Invalid jmespath expression: #{name}() requires an expression reference") unless ref_arg.is_a?(ExpRef)
        ref = ref_arg

        if name == "map"
          list_node = node.args[1]?
          list_value = list_node ? eval_node(list_node, data, false).value : NULL
          raise Error.new("Invalid jmespath expression: map() requires an array") unless array = list_value.as_a?
          return JSON::Any.new(array.map { |element| eval_node(ref.expr, element, false).value })
        end

        raise Error.new("Invalid jmespath expression: #{name}() first argument must be an array") unless array = data.as_a?

        key = ->(element : JSON::Any) do
          eval_node(ref.expr, element, false).value
        end

        case name
        when "min_by"
          sort_by_key(array, key).first? || NULL
        when "max_by"
          sort_by_key(array, key).last? || NULL
        else # sort_by
          JSON::Any.new(sort_by_key(array, key))
        end
      end

      private def sort_by_key(array : Array(JSON::Any), key : Proc(JSON::Any, JSON::Any)) : Array(JSON::Any)
        array.sort do |x, y|
          order(key.call(x), key.call(y))
        end
      end

      private def sort_array(array : Array(JSON::Any)) : Array(JSON::Any)
        array.sort { |x, y| order(x, y) }
      end

      private def sorted_min_max(value : JSON::Any?, what : String) : JSON::Any
        array = value.try(&.as_a?)
        raise Error.new("Invalid jmespath expression: #{what}() requires an array") unless array
        return NULL if array.empty?
        sorted = sort_array(array)
        (what == "min" ? sorted.first : sorted.last)
      end

      private def as_number(value : JSON::Any, what : String) : Float64
        raw = value.raw
        if raw.is_a?(Int64)
          raw.to_f
        elsif raw.is_a?(Float64)
          raw
        else
          raise Error.new("Invalid jmespath expression: #{what}() requires a number")
        end
      end
    end
  end
end
