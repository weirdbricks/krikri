require "../spec_helper"
require "../../src/krikri/crinja_strict_undefined"
require "../../src/krikri/jinja_filters"

private def render(tpl : String, vars = Hash(String, Crinja::Value).new) : String
  env = Crinja.new
  env.from_string(tpl).render(vars)
end

private def render_strict(tpl : String, vars = Hash(String, Crinja::Value).new) : String
  Krikri::StrictTemplating.strict { render(tpl, vars) }
end

private def hostvars_value : Crinja::Value
  Krikri::VariableSubstitutor::CrinjaRenderer.convert_hostvars(
    JSON.parse(%({"node1": {"ansible_host": "10.0.0.1", "ansible_enp0s8": "ok"}})),
    Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new),
  )
end

describe Krikri::StrictTemplating do
  it "renders an undefined variable as empty text when NOT strict (Crinja's default)" do
    render("token = {{ nope }}").should eq("token = ")
  end

  it "raises for an undefined variable inside the strict block" do
    # Real Ansible's template: module runs Jinja2 with StrictUndefined:
    # verified live against ansible-core 2.19 - a .j2 referencing an
    # undefined variable fails the task with "'x' is undefined" rather
    # than silently deploying a config with an empty value in its place
    # (alannix_lw.lacework_agent_ansible_role's config.json.j2 and its
    # "AccessToken" : "{{ lacework_accessToken }}").
    ex = expect_raises(Crinja::UndefinedError) do
      render_strict(%(token = {{ lacework_accessToken }}))
    end
    ex.variable_name.should eq("lacework_accessToken")
  end

  it "still resolves defined variables under strict" do
    vars = {"greeting" => Crinja::Value.new("hello")}
    render_strict("{{ greeting }}", vars).should eq("hello")
  end

  it "leaves `default()` and `is defined` lenient under strict" do
    # Both only ever test `undefined?` and never stringify the value, so
    # the legitimate (and extremely common) guarded idioms must keep
    # working - exactly as they do in real Jinja2's StrictUndefined.
    render_strict("{{ nope | default('fallback') }}").should eq("fallback")
    render_strict("{{ 'yes' if nope is not defined else 'no' }}").should eq("yes")
  end

  it "restores lenient resolution after the strict block exits" do
    render_strict("{{ nope | default('x') }}").should eq("x")
    render("token = {{ nope }}").should eq("token = ")
  end

  it "restores lenient resolution even when the strict block raises" do
    expect_raises(Crinja::UndefinedError) { render_strict("{{ nope }}") }
    render("token = {{ nope }}").should eq("token = ")
  end

  it "keeps global functions resolvable under strict" do
    # `resolve`'s function-fallback branch must run BEFORE the strict
    # branch, or every registered global (range, dict, ...) would read
    # as an undefined bare name.
    render_strict("{{ range(3) | list | join(',') }}").should eq("0,1,2")
  end
end

# hostvars' per-host dicts raise on an attribute/subscript miss under
# strict templating - real Ansible's own HostVarsVars wrapper (found via
# mrlesmithjr.ansible_consul_client's
# `hostvars[inventory_hostname]['ansible_' + iface]` with an interface
# that doesn't exist on the real host). Outside strict mode the miss
# stays lenient (the hand-rolled evaluator and `when:` conditions read
# these values, and a blanket-strict hash accessor was the rejected
# approach - see HostVarsVarsDict's own comment).
describe Krikri::HostVarsVarsDict do
  it "resolves a present attribute/subscript" do
    value = hostvars_value
    Crinja.new.from_string("{{ hostvars['node1']['ansible_host'] }}").render({"hostvars" => value})
      .should eq("10.0.0.1")
    Crinja.new.from_string("{{ hostvars['node1'].ansible_host }}").render({"hostvars" => value})
      .should eq("10.0.0.1")
  end

  it "stays lenient for a missing attribute when NOT strict" do
    value = hostvars_value
    Crinja.new.from_string("[{{ hostvars['node1']['ansible_enp1s0'] }}]").render({"hostvars" => value})
      .should eq("[]")
  end

  it "raises with real Ansible's HostVarsVars message on a strict miss (subscript)" do
    value = hostvars_value
    ex = expect_raises(Crinja::RuntimeError) do
      Krikri::StrictTemplating.strict do
        Crinja.new.from_string("[{{ hostvars['node1']['ansible_enp1s0'] }}]").render({"hostvars" => value})
      end
    end
    ex.message.should contain("object of type 'HostVarsVars' has no attribute 'ansible_enp1s0'")
  end

  it "raises with real Ansible's HostVarsVars message on a strict miss (attribute)" do
    value = hostvars_value
    expect_raises(Crinja::RuntimeError, "has no attribute 'ansible_enp1s0'") do
      Krikri::StrictTemplating.strict do
        Crinja.new.from_string("{{ hostvars['node1'].ansible_enp1s0 }}").render({"hostvars" => value})
      end
    end
  end

  it "leaves plain (non-hostvars) dicts lenient even under strict" do
    # the blanket-strict hash accessor was the rejected approach - a
    # plain dict miss must stay lenient under strict, exactly as before
    vars = {"d" => Crinja::Value.new({"k" => Crinja::Value.new("v")})}
    Krikri::StrictTemplating.strict do
      Crinja.new.from_string("[{{ d.missing }}]").render(vars).should eq("[]")
    end
  end
end
