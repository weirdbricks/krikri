require "crinja"

# Real Jinja2's `namespace()` builtin creates a mutable-attribute object
# that, unlike a plain `{% set %}` variable, is NOT re-scoped fresh on
# each `{% for %}` iteration - the standard way to accumulate/mutate
# state across a loop in Jinja2, since a bare `{% set %}` inside a
# `{% for %}` body is invisible outside that one iteration (a deliberate
# Jinja2 scoping rule people constantly get bitten by - `namespace()`
# exists specifically to work around it). Entirely unregistered in
# Crinja - `{{ namespace() }}` failed with "is undefined" (not even a
# parse error - a plain missing-function lookup failure), found via
# prometheus.prometheus's own `roles/_common/templates/
# node_exporter.service.j2` (round 21, see CRINJA.md bug #3):
#
#   {% set ns = namespace(protect_home = 'yes') %}
#   {% for m in ansible_facts['mounts'] if m.mount.startswith('/home') %}
#   {%   set ns.protect_home = 'read-only' %}
#   {% endfor %}
#   ProtectHome={{ ns.protect_home }}
#
# Two genuinely separate features, both needed for the above to work:
# the `namespace()` runtime object itself (this file's `Namespace` class
# + the `Crinja.function(:namespace)` registration), and `{% set
# ns.attr = ... %}` dotted-target assignment syntax - real Jinja2's
# `{% set %}` otherwise only ever supports a bare name target, so
# namespace objects are specifically the one exception to that rule
# (this file's `Tag::Set#interpret` override).
#
# A THIRD, unrelated `{% set %}` target shape got added to the same
# override later (2026-08-13, same live-verification pass that found the
# two features above needed real-host confirmation, not just a unit
# test): `{% set a, b = expr %}` real Jinja2 tuple-target assignment,
# found a few lines further into this exact same real template
# (`{% set name, options = (collector.items()|list)[0] %}`) once
# `namespace()` itself stopped being the blocker. Lives here rather than
# a separate file because `Tag::Set#interpret` can only have ONE active
# definition - splitting it across files would just make the last-loaded
# one silently clobber the others.
class Crinja::Namespace
  include Crinja::Object

  def initialize(@data = Hash(String, Crinja::Value).new)
  end

  def []=(key : String, value : Crinja::Value)
    @data[key] = value
  end

  def crinja_attribute(attr : Crinja::Value) : Crinja::Value
    key = attr.to_s
    @data.fetch(key) { Crinja::Value.new(Crinja::Undefined.new(key)) }
  end
end

Crinja.function(:namespace) do
  ns = Crinja::Namespace.new
  arguments.kwargs.each do |key, value|
    ns[key] = value
  end
  Crinja::Value.new(ns)
end

# Full method replacement (matches this codebase's pattern for the other
# `Tag::Set`-shaped extension) - vendored `interpret` only handles the
# block-set form (`{% set x %}...{% endset %}`) and the plain
# `identifier = expr[, identifier = expr, ...]` form via
# `parse_keyword_list`, which itself only ever accepts a bare
# `AST::IdentifierLiteral` target (`expression_parser.cr`'s
# `parse_keyword_list`, shared with filter/function keyword-argument
# parsing, so widening it there directly would be a much bigger blast
# radius than this one tag needs). Adds a third branch, checked before
# falling through to the existing keyword-list path: `IDENTIFIER "."
# IDENTIFIER "=" expr`, evaluated by resolving the target identifier to a
# `Crinja::Namespace` and mutating it in place (never rebinding
# `env.context[target_name]`, which is what makes the mutation visible
# outside the current `{% for %}` iteration - `env.context` lookups
# inside the loop body still resolve to the SAME `Namespace` object set
# once, before the loop, so mutating its internal Hash is visible
# everywhere that reference is reachable, exactly matching real Jinja2's
# namespace semantics).
class Crinja::Tag::Set
  private def interpret(io : IO, renderer : Crinja::Renderer, tag_node : TagNode)
    env = renderer.env
    args = ArgumentsParser.new(tag_node.arguments, renderer.env.config)

    if tag_node.arguments.size == 2
      # IDENTIFIER + EOF
      name = args.current_token.value
      args.next_token
      value = renderer.render(tag_node.block).value
      env.context[name] = SafeString.new(value)
      args.close
    elsif args.current_token.kind == Crinja::Parser::Token::Kind::IDENTIFIER &&
          (peeked = args.peek_token?) && peeked.kind == Crinja::Parser::Token::Kind::POINT
      target_name = args.current_token.value
      args.next_token # consume target identifier
      args.next_token # consume "."

      unless args.current_token.kind == Crinja::Parser::Token::Kind::IDENTIFIER
        raise TemplateSyntaxError.new(args.current_token, "expected attribute name in namespace assignment")
      end
      attr_name = args.current_token.value
      args.next_token # consume attribute identifier

      unless args.current_token.kind == Crinja::Parser::Token::Kind::KW_ASSIGN
        raise TemplateSyntaxError.new(args.current_token, "expected '=' in namespace attribute assignment")
      end
      args.next_token # consume "="

      value = env.evaluate(args.parse_expression)

      target = env.resolve(target_name)
      ns = target.raw
      unless ns.is_a?(Crinja::Namespace)
        raise TemplateSyntaxError.new(args.current_token, "'#{target_name}' is not a namespace object, cannot assign attribute '#{attr_name}'")
      end
      ns[attr_name] = value

      args.close
    elsif args.current_token.kind == Crinja::Parser::Token::Kind::IDENTIFIER &&
          (peeked2 = args.peek_token?) && peeked2.kind == Crinja::Parser::Token::Kind::COMMA
      # `{% set a, b = expr %}` - real Jinja2's tuple-target assignment
      # (distinct from `parse_keyword_list`'s own `a = x, b = y` repeated-
      # single-assignment syntax below - disambiguated by whether the
      # token right after the first identifier is a comma, meaning
      # another bare target name follows, or `=`, meaning a value).
      # Evaluates the right-hand side ONCE and unpacks it positionally
      # across every target name - found via prometheus.prometheus._
      # common's own node_exporter.service.j2: `{% set name, options =
      # (collector.items()|list)[0] %}`.
      targets = [] of String
      targets << args.current_token.value
      args.next_token
      while args.current_token.kind == Crinja::Parser::Token::Kind::COMMA
        args.next_token
        unless args.current_token.kind == Crinja::Parser::Token::Kind::IDENTIFIER
          raise TemplateSyntaxError.new(args.current_token, "expected identifier in set tuple-target list")
        end
        targets << args.current_token.value
        args.next_token
      end

      unless args.current_token.kind == Crinja::Parser::Token::Kind::KW_ASSIGN
        raise TemplateSyntaxError.new(args.current_token, "expected '=' in set tuple assignment")
      end
      args.next_token

      items = env.evaluate(args.parse_expression).each.to_a
      targets.each_with_index do |target_name, i|
        env.context[target_name] = items[i]? || Crinja::UNDEFINED
      end

      args.close
    else
      args.parse_keyword_list.each do |identifier, expr|
        env.context[identifier.name] = env.evaluate(expr)
      end
      args.close
    end
  end
end
