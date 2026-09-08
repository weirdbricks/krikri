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

  # The per-host dicts inside `hostvars` in a Crinja render. Real Ansible
  # wraps each host's vars in its own HostVarsVars object, whose attribute
  # lookup RAISES on a miss (`object of type 'HostVarsVars' has no
  # attribute 'ansible_enp0s8'` - a typo'd/computed interface fact name
  # fails the task rather than rendering an empty value in its place;
  # found via mrlesmithjr.ansible_consul_client's
  # `hostvars[inventory_hostname]['ansible_' + consul_client_bind_interface]`
  # with a bind interface that doesn't exist on the real host). Crinja's
  # plain dict resolution (Resolver#resolve_with_hash_accessor) falls back
  # to a lenient Undefined on the same miss, and that path can't be made
  # blanket-strict (it is also the fallback for method-call dispatch and
  # for this engine's own fact-coverage gaps - see
  # Krikri::StrictTemplating's own comment). So the strictness rides on
  # the hostvars VALUE ITSELF: the dict only reaches a render through the
  # hostvars conversion (CrinjaRenderer.convert_hostvars), and its `[]?`
  # raises on a miss exactly when strict templating is enabled for the
  # rendering fiber - every non-hostvars dict stays lenient, and outside
  # strict mode (where the lenient `{{ ... }}` hand-rolled evaluator and
  # `when:` conditions read these values) the behavior is unchanged.
  # A Crinja::Object wrapper rather than a Hash subclass: Crinja::Value.new
  # NORMALIZES any Hash into a plain Crinja::Dictionary (Crinja.value's
  # Hash case), which would silently strip a subclass - only Crinja::Object
  # instances survive as their own raw object.
  class HostVarsVarsDict
    include Crinja::Object

    @entries = Hash(String, Crinja::Value).new

    def initialize(@entries : Hash(String, Crinja::Value))
    end

    # Both the attribute form (`hostvars[h].ansible_host`) and the
    # subscript form (`hostvars[h]['ansible_host']`) funnel through
    # resolve_getattr -> crinja_attribute for a Crinja::Object.
    #
    # The strict raise is a plain RuntimeError, NOT an UndefinedError:
    # Crinja's own evaluator rescues UndefinedError around attribute
    # resolution and re-raises a generic "hostvars[node1][x] is
    # undefined" that DISCARDS the cause's message - real Ansible's
    # failure text for this exact case is the wrapper's own
    # "object of type 'HostVarsVars' has no attribute ..." (an
    # AttributeError surfacing verbatim), so the detail has to survive.
    # A RuntimeError is not swallowed anywhere in the render path and
    # surfaces the message as the task failure.
    def crinja_attribute(attr : Crinja::Value) : Crinja::Value
      key = attr.to_string
      return @entries[key] if @entries.has_key?(key)
      raise Crinja::RuntimeError.new("object of type 'HostVarsVars' has no attribute '#{key}'") if Krikri::StrictTemplating.enabled?
      Crinja::Value.new(Crinja::Undefined.new(key))
    end

    def crinja_call(name : String) : Crinja::Callable | Crinja::Callable::Proc | Nil
      nil
    end

    # dict-protocol compatibility for the operations templates actually
    # perform on a host's vars (size/iteration/key listing); the plain
    # Hash(String, Crinja::Value) these delegate to is also what every
    # other code path sees, since @entries stays directly readable.
    delegate size, keys, has_key?, to: @entries

    def each(&)
      @entries.each { |key, value| yield key, value }
    end

    def to_s(io : IO) : Nil
      io << @entries.to_s
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
