require "crinja"

# Python/Jinja2 string subscript (`mystr[0]`, `elasticsearch_version[0]`,
# `ansible_python_version[0]`) through Crinja.
#
# The vendored Resolver's undefined-value integer-subscript fallback is
# gated on `Value#indexable?`, which checks `@raw.is_a?(Indexable)`. The
# Crystal versions Crinja was originally written against included String
# in Indexable (its own `Value#[]?(index : Int)` still has an explicit
# `String, SafeString` branch for exactly this), but modern Crystal
# dropped String from Indexable - so for a plain String value,
# `resolve_with_hash_accessor` (which EXCLUDES strings from dict-style
# access, correctly) returns Undefined, the integer fallback never runs
# (`indexable?` is false), and `{{ mystr[0] }}` renders as empty/"".
#
# Found via louim.bedrock-site-protect's `passlib_package[
# ansible_python_version[0]]` - the fact itself was populated fine; only
# the inner string index failed, rendering "undefined" into both the
# task name and the package-name lookup. Real Jinja2/Python treats a
# string as an indexable sequence (integer subscript yields a one-char
# string, negative indices count from the end), so restoring `string?`
# to `indexable?`'s meaning is exactly the right shape - the resolver's
# fallback then dispatches through the already-correct
# `Value#[]?(index : Int)` String branch.
struct Crinja::Value
  def indexable? : Bool
    @raw.is_a?(Indexable) || string?
  end
end
