require "crinja"

# `Evaluator#name_for_expression` builds a human-readable name for the
# thing that turned out undefined, to attach to the `UndefinedError` it
# re-raises (`visit MemberExpression`/`visit IndexExpression`'s own
# `rescue exc : UndefinedError` blocks). It only has overloads for
# `IdentifierLiteral`/`MemberExpression`/`IndexExpression` - anything
# else (a `CallExpression`, a `DictLiteral`/`ArrayLiteral`/`StringLiteral`
# literal used directly as a receiver, this codebase's own `CondExpr`
# ternary node, ...) falls through to a generic `raise "not implemented
# for #{expression.class}"` - turning what should be a clean "no such
# method/attribute" error into an opaque internal crash instead. Found
# via `{'i386': ...}.get(my_arch, my_arch)` (a dict LITERAL calling
# `.get()`, itself unimplemented before `crinja_hash_ext.cr`'s own fix
# above - `.get` failing internally with `UndefinedError` triggered this
# fallback, and a dict literal isn't an `IdentifierLiteral`/
# `MemberExpression`/`IndexExpression`) and `' '.join(x).split()`
# (chained method calls - the OUTER `.split` call's receiver is a
# `CallExpression`, not a simple identifier chain, when `.join` itself
# was still unimplemented and raised `UndefinedError`).
#
# Rather than adding overloads for every possible AST node type
# one-by-one forever (open-ended, and this codebase can't enumerate
# every node type vendored Crinja ships or might add later), this
# reopens the SAME generic fallback to degrade gracefully - a
# best-effort description via the node's own `to_s`, never a hard
# crash - instead of a full replacement duplicating every existing
# overload. `previous_def` would replace this one function's body
# entirely for the SAME overload signature (there's nothing "previous"
# to chain to at this exact overload - the specific-type overloads
# above it in the vendored file still win via normal overload
# resolution, this only ever fires when none of them match), so this is
# effectively a full replacement, but of the LEAST specific overload
# only, leaving IdentifierLiteral/MemberExpression/IndexExpression's own
# precise formatting untouched.
class Crinja::Evaluator
  private def name_for_expression(expression)
    expression.to_s
  end
end
