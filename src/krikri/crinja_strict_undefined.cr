require "crinja"

module Krikri
  # Opt-in strict-undefined mode for Crinja renders.
  #
  # Real Ansible's `template:` module runs Jinja2 with `StrictUndefined`:
  # `{{ some_undefined_var }}` in a `.j2` file raises
  # `'some_undefined_var' is undefined` and fails the task. Crinja's
  # default is lenient - a miss resolves to the shared, NAMELESS
  # `Value::UNDEFINED` singleton, which stringifies to "" - so a role
  # whose required credential was never provided rendered a config with
  # an empty value in place of it and reported `changed`, deploying a
  # broken/incomplete file while reporting success (found via
  # alannix_lw.lacework_agent_ansible_role's `config.json.j2`:
  # `"AccessToken" : "{{ lacework_accessToken }}"`).
  #
  # Crinja already ships `Crinja::StrictUndefined` (raises on `to_s`/
  # comparison) but nothing lets a caller opt an `Environment` into it -
  # `Crinja::Config` has no such setting, and the three separate sites
  # that build an undefined (`Context#undefined`, `Environment#undefined`,
  # `Resolver.resolve_with_hash_accessor`) each construct a plain one.
  # Rather than fork the vendored shard (whose `lib/` isn't even carried
  # in this repo), this reopens the ONE site that matters for the
  # documented failure - `Resolver#resolve`, the bare-name lookup - and
  # returns a named `StrictUndefined` from it while the flag is on.
  # Everything downstream then behaves as real Jinja2 does: `is defined`
  # and `default(...)` still work (both only ever test `undefined?`,
  # never stringify), while any attempt to actually PRINT the value
  # raises `Crinja::UndefinedError`, which `TemplateActionPlugin`
  # surfaces as a failed task.
  #
  # Deliberately scoped to bare-name misses only. A DOTTED attribute miss
  # on a defined object (`{{ foo.bar }}`) is strict in real Jinja2 too,
  # but goes through `Resolver.resolve_with_hash_accessor`, which is also
  # the fallback path for method-call dispatch and for this engine's own
  # fact-coverage gaps - making it strict risks false positives across the
  # whole existing template corpus, which is worse than the status quo it
  # would be fixing. Same reasoning for `{% if undefined %}`: Crinja's
  # `Value#truthy?` short-circuits on `undefined?` before any comparison
  # can raise, and leaving it lenient keeps this change to exactly the
  # shape that was found to bite.
  module StrictTemplating
    # Keyed by fiber, not a bare flag: hosts run their tasks in separate
    # fibers, so a plain class-level boolean set by one host's template
    # render could leak into another host's unrelated (deliberately
    # lenient) Crinja use if the render ever yields.
    @@active = Set(UInt64).new

    def self.enabled? : Bool
      return false if @@active.empty?
      @@active.includes?(Fiber.current.object_id)
    end

    # Runs *block* with strict-undefined resolution enabled for the
    # current fiber. Re-entrant: a nested call (a `{% include %}`'d
    # template rendering through the same environment) leaves the flag
    # set for the outer one.
    def self.strict(&)
      id = Fiber.current.object_id
      added = @@active.add?(id)
      begin
        yield
      ensure
        @@active.delete(id) unless added.nil?
      end
    end
  end
end

module Crinja::Resolver
  # Redefines the vendored shard's own `resolve` (see
  # `Krikri::StrictTemplating` for the full rationale). Identical to it
  # apart from the strict branch.
  def resolve(name : String) : Value
    value = context[name]
    if value.undefined? && functions.has_key?(name)
      Value.new functions[name]
    elsif value.undefined? && ::Krikri::StrictTemplating.enabled?
      Value.new(::Crinja::StrictUndefined.new(name))
    else
      value
    end
  end
end
