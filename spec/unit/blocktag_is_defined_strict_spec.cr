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

  # Real bug found via a 400-role regression sweep, benchmarking
  # buluma.postfix: the "is defined" tolerance above only ever applied
  # to a reference living INSIDE the SAME `{% %}` tag as its own `is
  # defined` test. The block-tag scan processed every `{% %}` tag in a
  # template independently, so a SEPARATE, later `{% if X is string
  # %}` tag - lexically nested inside an earlier `{% if X is defined
  # %}`'s true-branch, but a wholly different tag - had no way to know
  # it could only ever be reached once X was already proven defined,
  # and raised "'X' is undefined" where real ansible-playbook (verified
  # live, ansible-core 2.19.11) short-circuits the entire guarded
  # branch away and never evaluates it at all.
  describe "nesting across SEPARATE {% %} tags (not just within one)" do
    it "buluma.postfix's own real shape: is-defined guard, then the same var reused in a nested {% if %}/{% elif %}/{% for %}" do
      sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")

      # Verbatim from buluma.postfix's tasks/main.yml (Setting values
      # for main.cf (2/2)) - real ansible-playbook renders " <None> "
      # when postfix_relay_domains is unset.
      result = sub.substitute(
        "{% if postfix_relay_domains is defined %} {% if postfix_relay_domains is string %} " \
        "{{ postfix_relay_domains }} {% elif postfix_relay_domains is iterable and " \
        "(postfix_relay_domains is not string and postfix_relay_domains is not mapping) %} " \
        "{% for domain in postfix_relay_domains %}{{ domain }}{% if not loop.last %}, {% endif %}" \
        "{% endfor %} {% endif %} {% else %} <None> {% endif %}",
        strict: true
      )

      result.should eq(" <None> ")
    end

    it "carries the guarantee through a genuinely nested {% if %} (not just one level)" do
      sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")

      sub.substitute(
        "{% if x is defined %}{% if x is string %}{% if x is not mapping %}A{% endif %}{% endif %}{% else %}B{% endif %}",
        strict: true
      ).should eq("B")
    end

    it "does NOT carry the guarantee into the {% else %} branch of the SAME if" do
      sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")

      # Real Jinja gives no guarantee that `q` is defined inside the
      # `else` of `{% if q is defined %}` - reaching else means the
      # guard was FALSE, so a reference to q there is exactly as
      # undefined as it ever was.
      expect_raises(Krikri::UndefinedVariableError, /'q' is undefined/) do
        sub.substitute(
          "{% if q is defined %}yes{% else %}{% if q is string %}str{% endif %}{% endif %}",
          strict: true
        )
      end
    end

    it "does NOT carry the guarantee into an unrelated {% elif %} clause" do
      sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")

      expect_raises(Krikri::UndefinedVariableError, /'q' is undefined/) do
        sub.substitute(
          "{% if other_var is defined %}A{% elif q is string %}B{% endif %}",
          strict: true
        )
      end
    end

    it "still raises for an unguarded reference nested inside an unrelated guarded {% if %}" do
      sub = Krikri::VarSubstitutor.new(vars: {"x" => JSON::Any.new(true)}, host_name: "h")

      # x is genuinely defined, but that guarantees nothing about y -
      # the nesting fix must not become "anything inside any {% if %}
      # is exempt", only "a variable an ENCLOSING is-defined test
      # actually named".
      expect_raises(Krikri::UndefinedVariableError, /'y' is undefined/) do
        sub.substitute(
          "{% if x %}{% if y %}yes{% endif %}{% endif %}",
          strict: true
        )
      end
    end
  end
end
