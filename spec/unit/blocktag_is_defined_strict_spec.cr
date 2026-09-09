require "../spec_helper"
require "../../src/krikri/variable_substitutor"

# Real bug found benchmarking ruzickap.proxy_settings: its blockinfile
# task's `block:` param is a task-param STRING containing a `{% if %}`
# block tag inline - `block: "{% if proxy_settings_http_proxy is
# defined %}...{% endif %}"` - with the variable deliberately commented
# out of the role's defaults (genuinely undefined). The strict
# `{% %}` block-tag pre-render scan (scan_block_tag_refs) raised
# "'proxy_settings_http_proxy' is undefined" before Crinja ever
# rendered, where real Ansible's Jinja2 takes the false branch and the
# whole block renders empty/skipped. The `{{ }}`-span scanner already
# honored the `is defined`-family tolerance via
# block_tag_ref_is_defined_test; the block-tag scan simply never
# called that helper.
describe "strict block-tag scan: `is defined` on a plain undefined variable never raises" do
  it "renders the ELSE branch for `{% if undefined_var is defined %}`" do
    sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")

    sub.substitute(
      "{% if proxy_settings_http_proxy is defined %}A{% else %}B{% endif %}",
      strict: true
    ).should eq("B")
  end

  it "renders the TRUE branch when the variable IS defined (no regression)" do
    sub = Krikri::VarSubstitutor.new(
      vars: {"proxy_settings_http_proxy" => JSON::Any.new("http://proxy:3128")},
      host_name: "h"
    )

    sub.substitute(
      "{% if proxy_settings_http_proxy is defined %}A{% else %}B{% endif %}",
      strict: true
    ).should eq("A")
  end

  it "renders the ELSE branch for `{% if undefined_var is not defined %}`" do
    sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")

    sub.substitute(
      "{% if proxy_settings_http_proxy is not defined %}B{% else %}A{% endif %}",
      strict: true
    ).should eq("B")
  end

  it "renders the ELSE branch for `{% if undefined_var is undefined %}`" do
    sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")

    sub.substitute(
      "{% if proxy_settings_http_proxy is undefined %}B{% else %}A{% endif %}",
      strict: true
    ).should eq("B")
  end

  it "still flags a genuinely undefined BARE variable inside an {% if %} (no regression)" do
    sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")

    expect_raises(Krikri::UndefinedVariableError, /'nosuch_var' is undefined/) do
      sub.substitute(
        "{% if nosuch_var == 'x' %}A{% else %}B{% endif %}",
        strict: true
      )
    end
  end
end
