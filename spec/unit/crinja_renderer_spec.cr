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
end
