require "../spec_helper"
require "../../src/crystal_play/variable_substitutor/crinja_renderer"

describe CrystalPlay::VariableSubstitutor::CrinjaRenderer do
  it "re-templates a variable whose own value is itself a {{ }} expression" do
    # Real bug found benchmarking geerlingguy.nginx: role defaults/main.yml
    # commonly defines a var whose *value* is itself more Jinja -
    # `nginx_worker_processes: '"{{ ansible_processor_vcpus | default(
    # ansible_processor_count) }}"'` - relying on real Ansible's own
    # recursive re-templating of every variable value wherever it's used,
    # including inside a real .j2 template FILE (not just a plain task
    # param `{{ }}`, which VarSubstitutor#substitute already handles via
    # its own multi-pass loop). Real Jinja2 itself has no such recursive
    # behavior - a variable's string value is just a string to it - so
    # `{{ nginx_worker_processes }}` in nginx.conf.j2 rendered the
    # literal, still-unparsed inner `{{ ... }}` text straight into the
    # config file, which nginx's own parser then rejected outright
    # ("worker_processes directive invalid value").
    v = Hash(String, JSON::Any).new
    v["ansible_processor_count"] = JSON::Any.new(1_i64)
    v["nginx_worker_processes"] = JSON::Any.new(%("{{ ansible_processor_vcpus | default(ansible_processor_count) }}"))
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("worker_processes  {{ nginx_worker_processes }};").should eq(%(worker_processes  "1";))
  end

  it "leaves an ordinary variable (no embedded template) unaffected" do
    v = Hash(String, JSON::Any).new
    v["greeting"] = JSON::Any.new("hello")
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ greeting }}, world").should eq("hello, world")
  end

  it "defaults the comment filter to a bare '#' style" do
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ 'Ansible managed' | comment }}").should eq("#\n# Ansible managed\n#")
  end

  it "exposes the whole variable scope under the 'vars' magic variable, for dynamic-key lookups" do
    # Real bug found benchmarking openstack.ansible-hardening's own
    # audit-rule template: `{% if vars['security_rhel7_audit_' +
    # command_sanitized] | bool %}` (picking which of ~40 individually-
    # named enable/disable flags applies to the audit rule currently
    # being rendered) - real Ansible's own `vars` magic variable, a dict
    # of the whole current scope, entirely absent before ("vars is
    # undefined" failed the whole template render outright).
    v = Hash(String, JSON::Any).new
    v["security_rhel7_audit_foo"] = JSON::Any.new(true)
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ vars['security_rhel7_audit_foo'] }}").should eq("true")
  end

  it "honors decoration= for a non-'#' comment style" do
    # Real bug found benchmarking geerlingguy.php: `{{ ansible_managed |
    # comment(decoration='; ') }}` (www.conf.j2's own header, a php-fpm
    # INI-style pool file) previously ignored decoration= entirely and
    # always used "#" - not a valid INI comment character, so php-fpm's
    # own config parser rejected the file outright at startup ("value is
    # NULL for a ZEND_INI_PARSER_ENTRY"), even though the file looked
    # fine to a human reader.
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render("{{ 'Ansible managed' | comment(decoration='; ') }}").should eq(";\n; Ansible managed\n;")
  end

  it "renders to_nice_yaml, real Ansible's own pretty-YAML filter" do
    # Real bug found benchmarking cloudalchemy.prometheus's own alerting-
    # rules template: `{{ prometheus_alert_rules | to_nice_yaml(indent=2,
    # sort_keys=False) }}` - to_nice_yaml was entirely unimplemented,
    # Crinja raised "no filter with name \"to_nice_yaml\" registered",
    # failing the whole template render (all-or-nothing).
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render(%({{ [{"name": "x", "rules": ["a", "b"]}] | to_nice_yaml }})).should eq(
      "- name: x\n  rules:\n  - a\n  - b"
    )
  end

  it "sorts to_nice_yaml's own mapping keys by default, honors sort_keys=False" do
    v = Hash(String, JSON::Any).new
    renderer = CrystalPlay::VariableSubstitutor::CrinjaRenderer.new(v)

    renderer.render(%({{ {"b": 1, "a": 2} | to_nice_yaml }})).should eq("a: 2\nb: 1")
    renderer.render(%({{ {"b": 1, "a": 2} | to_nice_yaml(sort_keys=False) }})).should eq("b: 1\na: 2")
  end
end
