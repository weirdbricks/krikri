require "json"

module Krikri::DifferentialFuzz
  # Typed fixture variables shared by the generator (which needs names and
  # type classes to build plausible expressions) and the runner (which needs
  # the actual values both evaluators see).
  module Fixtures
    TYPES = {
      "str_plain"     => "str",
      "str_empty"     => "str",
      "str_spaces"    => "str",
      "str_num"       => "str",
      "str_csv"       => "str",
      "int_pos"       => "int",
      "int_neg"       => "int",
      "int_zero"      => "int",
      "float_val"     => "float",
      "float_whole"   => "float",
      "bool_true"     => "bool",
      "bool_false"    => "bool",
      "none_var"      => "none",
      "list_ints"     => "list",
      "list_strs"     => "list",
      "list_mixed"    => "list",
      "list_empty"    => "list",
      "list_nested"   => "list",
      "dict_simple"   => "dict",
      "dict_nested"   => "dict",
      "list_of_dicts" => "list",
    }

    def self.build : Hash(String, JSON::Any)
      JSON.parse(<<-'JSON'
        {
          "str_plain": "hello world",
          "str_empty": "",
          "str_spaces": "  padded  ",
          "str_num": "17",
          "str_csv": "a,b,c",
          "int_pos": 42,
          "int_neg": -7,
          "int_zero": 0,
          "float_val": 3.14,
          "float_whole": 2.0,
          "bool_true": true,
          "bool_false": false,
          "none_var": null,
          "list_ints": [3, 1, 2],
          "list_strs": ["b", "a", "c"],
          "list_mixed": [1, "two", 3.5, true],
          "list_empty": [],
          "list_nested": [[1, 2], [3, 4]],
          "dict_simple": {"name": "web", "count": 3, "enabled": true},
          "dict_nested": {"outer": {"inner": [1, 2], "flag": false}, "port": 8080},
          "list_of_dicts": [{"k": "a", "v": 1}, {"k": "b", "v": 2}]
        }
        JSON
      ).as_h
    end

    def self.named : Array({String, String})
      TYPES.map { |name, type| {name, type} }
    end
  end

  abstract class Node
    # An operand position (left of `|`, before `.attr`/`[i]`, before `is`)
    # needs explicit parens for any node whose own rendering would
    # otherwise bind to the wrong construct - filters bind tighter than
    # `not`, and `x | trim.name` would not parse as `(x | trim).name`.
    private def operand_needs_parens?(node : Node) : Bool
      node.is_a?(Filter) || node.is_a?(Ternary) || node.is_a?(Test) ||
        (node.is_a?(Unary) && node.op == "not")
    end

    private def render_operand(node : Node, io : IO) : Nil
      if operand_needs_parens?(node)
        io << '(' << node.to_expr << ')'
      else
        node.render(io)
      end
    end
    abstract def render(io : IO) : Nil
    abstract def children : Array(Node)
    abstract def size : Int32
    abstract def type_hint : String
    abstract def replace(target : Node, replacement : Node) : Node

    def to_expr : String
      String.build { |io| render(io) }
    end

    # Every subtree (self first), for the shrinker's candidate walk.
    def each_node(&block : Node ->) : Nil
      yield self
      children.each(&.each_node(&block))
    end
  end

  class Literal < Node
    getter raw : JSON::Any

    def initialize(@raw : JSON::Any)
    end

    def children : Array(Node)
      [] of Node
    end

    def size : Int32
      1
    end

    def type_hint : String
      case raw.raw
      when String  then "str"
      when Int64   then "int"
      when Float64 then "float"
      when Bool    then "bool"
      when Nil     then "none"
      else              "any"
      end
    end

    def replace(target : Node, replacement : Node) : Node
      same?(target) ? replacement : self
    end

    def render(io : IO) : Nil
      case value = raw.raw
      when String  then io << "'" << value.gsub("'", "\\'") << "'"
      when Int64   then io << value
      when Float64 then io << value
      when Bool    then io << (value ? "True" : "False")
      when Nil     then io << "none"
      end
    end
  end

  class VarRef < Node
    getter name : String, type_hint : String

    def initialize(@name : String, @type_hint : String)
    end

    def children : Array(Node)
      [] of Node
    end

    def size : Int32
      1
    end

    def replace(target : Node, replacement : Node) : Node
      same?(target) ? replacement : self
    end

    def render(io : IO) : Nil
      io << name
    end
  end

  class Attr < Node
    getter base : Node, name : String

    def initialize(@base : Node, @name : String)
    end

    def children : Array(Node)
      [base] of Node
    end

    def size : Int32
      1 + base.size
    end

    def type_hint : String
      "any"
    end

    def replace(target : Node, replacement : Node) : Node
      return replacement if same?(target)
      replaced = base.replace(target, replacement)
      replaced.same?(base) ? self : Attr.new(replaced, name)
    end

    def render(io : IO) : Nil
      render_operand(base, io)
      io << '.' << name
    end
  end

  class Index < Node
    getter base : Node, index : Node

    def initialize(@base : Node, @index : Node)
    end

    def children : Array(Node)
      [base, index] of Node
    end

    def size : Int32
      1 + base.size + index.size
    end

    def type_hint : String
      "any"
    end

    def replace(target : Node, replacement : Node) : Node
      return replacement if same?(target)
      replaced_base = base.replace(target, replacement)
      replaced_index = index.replace(target, replacement)
      if replaced_base.same?(base) && replaced_index.same?(index)
        self
      else
        Index.new(replaced_base, replaced_index)
      end
    end

    def render(io : IO) : Nil
      render_operand(base, io)
      io << '['
      index.render(io)
      io << ']'
    end
  end

  class Filter < Node
    getter operand : Node, name : String, args : Array(Node)

    def initialize(@operand : Node, @name : String, @args : Array(Node))
    end

    def children : Array(Node)
      ([operand] + args)
    end

    def size : Int32
      1 + operand.size + args.sum(&.size)
    end

    def type_hint : String
      Filters.return_type(name)
    end

    def replace(target : Node, replacement : Node) : Node
      return replacement if same?(target)
      replaced_operand = operand.replace(target, replacement)
      replaced_args = args.map(&.replace(target, replacement))
      if replaced_operand.same?(operand) && replaced_args.zip(args).all? { |a, b| a.same?(b) }
        self
      else
        Filter.new(replaced_operand, name, replaced_args)
      end
    end

    def render(io : IO) : Nil
      render_operand(operand, io)
      io << " | " << name
      unless args.empty?
        io << '('
        args.join(", ", io, &.render(io))
        io << ')'
      end
    end
  end

  class BinOp < Node
    getter op : String, left : Node, right : Node

    def initialize(@op : String, @left : Node, @right : Node)
    end

    def children : Array(Node)
      [left, right] of Node
    end

    def size : Int32
      1 + left.size + right.size
    end

    def type_hint : String
      case op
      when "==", "!=", "<", ">", "<=", ">=", "and", "or" then "bool"
      when "~"                                           then "str"
      else                                                    "num"
      end
    end

    def replace(target : Node, replacement : Node) : Node
      return replacement if same?(target)
      replaced_left = left.replace(target, replacement)
      replaced_right = right.replace(target, replacement)
      if replaced_left.same?(left) && replaced_right.same?(right)
        self
      else
        BinOp.new(op, replaced_left, replaced_right)
      end
    end

    def render(io : IO) : Nil
      io << '('
      left.render(io)
      io << ' ' << op << ' '
      right.render(io)
      io << ')'
    end
  end

  class Unary < Node
    getter op : String, operand : Node

    def initialize(@op : String, @operand : Node)
    end

    def children : Array(Node)
      [operand] of Node
    end

    def size : Int32
      1 + operand.size
    end

    def type_hint : String
      op == "not" ? "bool" : "num"
    end

    def replace(target : Node, replacement : Node) : Node
      return replacement if same?(target)
      replaced = operand.replace(target, replacement)
      replaced.same?(operand) ? self : Unary.new(op, replaced)
    end

    def render(io : IO) : Nil
      io << op << ' '
      render_operand(operand, io)
    end
  end

  class Ternary < Node
    getter cond : Node, then_branch : Node, else_branch : Node

    def initialize(@cond : Node, @then_branch : Node, @else_branch : Node)
    end

    def children : Array(Node)
      [cond, then_branch, else_branch] of Node
    end

    def size : Int32
      1 + cond.size + then_branch.size + else_branch.size
    end

    def type_hint : String
      then_branch.type_hint
    end

    def replace(target : Node, replacement : Node) : Node
      return replacement if same?(target)
      replaced_cond = cond.replace(target, replacement)
      replaced_then = then_branch.replace(target, replacement)
      replaced_else = else_branch.replace(target, replacement)
      if replaced_cond.same?(cond) && replaced_then.same?(then_branch) && replaced_else.same?(else_branch)
        self
      else
        Ternary.new(replaced_cond, replaced_then, replaced_else)
      end
    end

    def render(io : IO) : Nil
      then_branch.render(io)
      io << " if "
      cond.render(io)
      io << " else "
      else_branch.render(io)
    end
  end

  class Test < Node
    getter operand : Node, name : String, negated : Bool, arg : Node?

    def initialize(@operand : Node, @name : String, @negated : Bool = false, @arg : Node? = nil)
    end

    def children : Array(Node)
      nodes = [operand] of Node
      if (a = arg)
        nodes << a
      end
      nodes
    end

    def size : Int32
      1 + operand.size + (arg.try(&.size) || 0)
    end

    def type_hint : String
      "bool"
    end

    def replace(target : Node, replacement : Node) : Node
      return replacement if same?(target)
      replaced_operand = operand.replace(target, replacement)
      if arg
        replaced_arg = arg.not_nil!.replace(target, replacement)
        if replaced_operand.same?(operand) && replaced_arg.same?(arg)
          self
        else
          Test.new(replaced_operand, name, negated, replaced_arg)
        end
      elsif replaced_operand.same?(operand)
        self
      else
        Test.new(replaced_operand, name, negated)
      end
    end

    def render(io : IO) : Nil
      render_operand(operand, io)
      io << (negated ? " is not " : " is ") << name
      if arg
        io << '('
        arg.not_nil!.render(io)
        io << ')'
      end
    end
  end

  class ListLiteral < Node
    getter items : Array(Node)

    def initialize(@items : Array(Node))
    end

    def children : Array(Node)
      items
    end

    def size : Int32
      1 + items.sum(&.size)
    end

    def type_hint : String
      "list"
    end

    def replace(target : Node, replacement : Node) : Node
      return replacement if same?(target)
      replaced = items.map(&.replace(target, replacement))
      replaced.zip(items).all? { |a, b| a.same?(b) } ? self : ListLiteral.new(replaced)
    end

    def render(io : IO) : Nil
      io << '['
      items.join(", ", io, &.render(io))
      io << ']'
    end
  end

  class DictLiteral < Node
    getter keys : Array(String), values : Array(Node)

    def initialize(@keys : Array(String), @values : Array(Node))
    end

    def children : Array(Node)
      values
    end

    def size : Int32
      1 + values.sum(&.size)
    end

    def type_hint : String
      "dict"
    end

    def replace(target : Node, replacement : Node) : Node
      return replacement if same?(target)
      replaced = values.map(&.replace(target, replacement))
      replaced.zip(values).all? { |a, b| a.same?(b) } ? self : DictLiteral.new(keys, replaced)
    end

    def render(io : IO) : Nil
      io << '{'
      keys.zip(values).join(", ", io) do |(key, value), inner|
        inner << "'" << key << "': "
        value.render(inner)
      end
      io << '}'
    end
  end

  # The filter/test registries the generator draws from: names both
  # evaluators are expected to know (ansible.builtin core set), each with
  # the operand type class it applies to and its declared return type.
  module Filters
    record Spec, name : String, param : String, ret : String, args : Array(String)

    SPECS = [
      Spec.new("trim", "str", "str", [] of String),
      Spec.new("upper", "str", "str", [] of String),
      Spec.new("lower", "str", "str", [] of String),
      Spec.new("capitalize", "str", "str", [] of String),
      Spec.new("length", "any", "int", [] of String),
      Spec.new("count", "any", "int", [] of String),
      Spec.new("abs", "num", "num", [] of String),
      Spec.new("int", "any", "int", [] of String),
      Spec.new("float", "any", "float", [] of String),
      Spec.new("string", "any", "str", [] of String),
      Spec.new("bool", "any", "bool", [] of String),
      Spec.new("list", "any", "list", [] of String),
      Spec.new("first", "seq", "any", [] of String),
      Spec.new("last", "seq", "any", [] of String),
      Spec.new("min", "list", "any", [] of String),
      Spec.new("max", "list", "any", [] of String),
      Spec.new("sort", "list", "list", [] of String),
      Spec.new("reverse", "seq", "any", [] of String),
      Spec.new("unique", "list", "list", [] of String),
      Spec.new("sum", "list", "num", [] of String),
      Spec.new("dictsort", "dict", "list", [] of String),
      Spec.new("join", "list", "str", ["str"]),
      Spec.new("default", "any", "any", ["any"]),
      Spec.new("d", "any", "any", ["any"]),
      Spec.new("replace", "str", "str", ["str", "str"]),
      Spec.new("split", "str", "list", ["str"]),
      Spec.new("round", "num", "float", ["int"]),
    ]

    def self.specs : Array(Spec)
      SPECS
    end

    def self.return_type(name : String) : String
      SPECS.find(&.name.==(name)).try(&.ret) || "any"
    end

    TESTS = [
      {name: "defined", param: "any", args: 0},
      {name: "undefined", param: "any", args: 0},
      {name: "string", param: "any", args: 0},
      {name: "number", param: "any", args: 0},
      {name: "boolean", param: "any", args: 0},
      {name: "none", param: "any", args: 0},
      {name: "iterable", param: "any", args: 0},
      {name: "mapping", param: "any", args: 0},
      {name: "sequence", param: "any", args: 0},
      {name: "even", param: "num", args: 0},
      {name: "odd", param: "num", args: 0},
      {name: "divisibleby", param: "num", args: 1},
    ]

    def self.tests
      TESTS
    end
  end

  # Structured, seeded expression generator: builds a typed AST (with
  # reasonable type compatibility between operators, filters and operands)
  # and serializes it to Jinja expression text. Deliberately type-mismatched
  # combinations are still produced at a controlled rate - how the two
  # evaluators treat invalid input is itself part of the contract under
  # test - but the bulk of generated expressions are valid.
  class Generator
    def initialize(@rng : Random, @max_depth : Int32 = 4)
      @vars = Fixtures.named
      @dict_keys = ["name", "count", "enabled", "outer", "port", "inner", "flag", "k", "v"]
    end

    def generate : Node
      gen(@max_depth)
    end

    private def gen(depth : Int32) : Node
      if depth <= 0 || @rng.rand(100) < 40
        leaf
      else
        case @rng.rand(100)
        when 0...35        then filter_chain(depth)
        when 35...62       then binop(depth)
        when 62...72       then ternary(depth)
        when 72...82       then test(depth)
        when 82...92       then attribute_or_index(depth)
        else                    unary(depth)
        end
      end
    end

    private def leaf : Node
      if @rng.rand(100) < 55
        var_ref
      else
        literal
      end
    end

    private def var_ref : Node
      name, type = @rng.rand(100) < 15 ? {"missing_var", "missing"} : @vars.sample(@rng)
      VarRef.new(name, type)
    end

    STRING_POOL = ["a", "b", "abc", "", "17", "3.5", "hello world", "x,y", "True"]

    private def literal : Node
      case @rng.rand(100)
      when 0...35
        Literal.new(JSON::Any.new(STRING_POOL.sample(@rng)))
      when 35...60
        Literal.new(JSON::Any.new(@rng.rand(-20_i64..20_i64)))
      when 60...80
        Literal.new(JSON::Any.new((@rng.rand(1..190).to_f / 10).round(2)))
      when 80...90
        Literal.new(JSON::Any.new(@rng.rand(2) == 0))
      else
        if @rng.rand(2) == 0
          Literal.new(JSON::Any.new(nil))
        else
          list_or_dict_literal
        end
      end
    end

    private def list_or_dict_literal : Node
      if @rng.rand(2) == 0
        ListLiteral.new(Array.new(@rng.rand(1..3)) { leaf })
      else
        keys = [["a"], ["a", "b"]].sample(@rng)
        DictLiteral.new(keys, Array.new(keys.size) { leaf })
      end
    end

    private def filter_chain(depth : Int32) : Node
      spec = Filters.specs.sample(@rng)
      operand = if spec.param == "any"
                  gen(depth - 1)
                else
                  typed_operand(spec.param, depth - 1)
                end
      # A controlled share of deliberately mismatched operands.
      operand = gen(depth - 1) if spec.param != "any" && @rng.rand(100) < 12
      args = spec.args.map { |arg_type| typed_leaf_or_expr(arg_type, depth) }
      Filter.new(operand, spec.name, args)
    end

    private def typed_operand(param : String, depth : Int32) : Node
      candidates = @vars.select do |_, type|
        case param
        when "str"  then type == "str"
        when "num"  then type == "int" || type == "float"
        when "int"  then type == "int"
        when "list" then type == "list"
        when "dict" then type == "dict"
        when "seq"  then type == "list" || type == "str"
        else             true
        end
      end
      if candidates.empty?
        gen(depth)
      else
        name, type = candidates.sample(@rng)
        VarRef.new(name, type)
      end
    end

    private def typed_leaf_or_expr(type : String, depth : Int32) : Node
      if depth <= 0 || @rng.rand(100) < 70
        case type
        when "str"   then Literal.new(JSON::Any.new([",", "-", "x", ""].sample(@rng)))
        when "int"   then Literal.new(JSON::Any.new(@rng.rand(0_i64..3_i64)))
        when "float" then Literal.new(JSON::Any.new(0.5))
        else              leaf
        end
      else
        gen(depth - 1)
      end
    end

    ARITHMETIC  = ["+", "-", "*", "/", "//", "%"]
    COMPARISONS = ["==", "!=", "<", ">", "<=", ">="]

    private def binop(depth : Int32) : Node
      op = case @rng.rand(100)
           when 0...40  then ARITHMETIC.sample(@rng)
           when 40...70 then COMPARISONS.sample(@rng)
           when 70...85 then "~"
           else              ["and", "or"].sample(@rng)
           end
      BinOp.new(op, gen(depth - 1), gen(depth - 1))
    end

    private def ternary(depth : Int32) : Node
      Ternary.new(comparisonish(depth - 1), gen(depth - 1), gen(depth - 1))
    end

    private def comparisonish(depth : Int32) : Node
      if depth <= 0 || @rng.rand(100) < 50
        leaf
      else
        BinOp.new(COMPARISONS.sample(@rng), leaf, leaf)
      end
    end

    private def test(depth : Int32) : Node
      test = Filters.tests.sample(@rng)
      operand = test[:param] == "any" ? gen(depth - 1) : typed_operand(test[:param], depth - 1)
      arg = test[:args] == 1 ? Literal.new(JSON::Any.new(@rng.rand(1_i64..4_i64))) : nil
      Test.new(operand, test[:name], @rng.rand(100) < 25, arg)
    end

    private def attribute_or_index(depth : Int32) : Node
      if @rng.rand(2) == 0
        base = @rng.rand(100) < 70 ? typed_operand("dict", depth - 1) : gen(depth - 1)
        name = @rng.rand(100) < 15 ? "missing_key" : @dict_keys.sample(@rng)
        Attr.new(base, name)
      else
        base = @rng.rand(100) < 70 ? typed_operand("seq", depth - 1) : gen(depth - 1)
        idx = @rng.rand(100) < 15 ? 9 : [0, 1, -1, 2].sample(@rng)
        Index.new(base, Literal.new(JSON::Any.new(idx.to_i64)))
      end
    end

    private def unary(depth : Int32) : Node
      op = @rng.rand(2) == 0 ? "not" : "-"
      operand = op == "not" ? gen(depth - 1) : typed_operand("num", depth - 1)
      Unary.new(op, operand)
    end
  end
end
