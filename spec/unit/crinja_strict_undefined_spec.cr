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
