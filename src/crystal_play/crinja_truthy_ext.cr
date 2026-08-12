require "crinja"

# Real Python/Jinja2 truthiness treats an empty String/Array/Hash as
# falsy (`bool("") == False`, `bool([]) == False`, `bool({}) == False`)
# - Crinja's own `Value#truthy?` (lib/crinja/src/runtime/value.cr) only
# special-cases `false`/`0`/`nil`/undefined, leaving an empty string,
# array, or hash truthy. This silently broke `and`/`or`
# (lib/crinja/src/lib/operator/logic.cr's And/Or both collapse straight
# to a Bool via `op.truthy?`, discarding the real Python short-circuit
# value) wherever both operands could be empty - found via
# geerlingguy.kibana's own kibana.yml.j2: `{% if
# kibana_elasticsearch_username and kibana_elasticsearch_password %}`
# (both default to "") rendered the `{% if %}` branch (a live, wrong
# `elasticsearch.username: ""`/`password: ""` pair) instead of real
# Ansible's own `{% else %}` branch (the commented-out placeholder).
# Verified against real Python's own jinja2.Environment directly, not
# just the real host's output. Reopening Crinja::Value (the sanctioned
# way to extend vendored Crinja behavior in this codebase - see
# crinja_hash_ext.cr's own doc comment) rather than editing the
# vendored lib/crinja file directly.
struct Crinja::Value
  def truthy?
    return false if undefined?

    case raw = @raw
    when Bool        then raw
    when Nil         then false
    when Number      then raw != 0
    when String      then !raw.empty?
    when SafeString  then raw.size != 0
    when Array(Value) then !raw.empty?
    when Dictionary  then !raw.empty?
    else
      true
    end
  end
end
