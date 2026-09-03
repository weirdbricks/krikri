require "../spec_helper"
require "../../src/krikri/variable_substitutor"

# Round 194 regression cover (andrewrothstein.openjdk on Ubuntu 22.04).
# vars/main.yml defines openjdk_install_subdir as
#   "{{ openjdk_install_dir }}/jdk-...{% if openjdk_app == \"jre\" %}
#    -jre{% endif %}"
# and a stat task uses `path: "{{ openjdk_install_subdir }}"`.
# Real ansible-core 2.19's strict Jinja2 environment raises on the
# undefined `openjdk_app` inside the `{% if %}` comparison (the `==`
# propagates the UndefinedError), aborting the task with rc=2 at
# "Finalization of task args for 'ansible.builtin.stat' failed:
# 'openjdk_app' is undefined". Crystal's Crinja-based render used to
# be lenient there - undefined == \"jre\" was falsy, the value
# rendered to the non-jre path, the stat succeeded, the block ran,
# and two more tasks failed with the same undefined (round-194
# marathon, role 5).
#
# The strict {% %}-block scan (scan_strict_block_tags_for_undefined
# in variable_substitutor.cr) now raises on an undefined bare ref
# inside a {% if %}/{% elif %}/{% for %}/{% set %} condition before
# Crinja is invoked. Loop-variables, `is defined`/`is failed` tests,
# filter names, and string literals are all carved out so normal
# playbooks don't false-positive.
describe Krikri::VarSubstitutor do
  describe "strict block-tag undefined scan (round 194 openjdk)" do
    it "raises on undefined bare ref inside {% if %} with strict: true" do
      v = {
        "openjdk_install_dir"    => JSON::Any.new("/usr/local/openjdk"),
        "openjdk_install_subdir" => JSON::Any.new("{{ openjdk_install_dir }}/jdk-16.0.1+9{% if openjdk_app == \"jre\" %}-jre{% endif %}"),
      } of String => JSON::Any
      sub = Krikri::VarSubstitutor.new(vars: v)
      # The outer value chains through the {% %} path at strict time.
      expect_raises(Krikri::UndefinedVariableError, /'openjdk_app' is undefined/) do
        sub.substitute("{{ openjdk_install_subdir }}", strict: true)
      end
    end

    it "renders fine when the if-referenced var is defined" do
      v = {
        "openjdk_install_dir"    => JSON::Any.new("/usr/local/openjdk"),
        "openjdk_app"            => JSON::Any.new("jre"),
        "openjdk_install_subdir" => JSON::Any.new("{{ openjdk_install_dir }}/jdk-16.0.1+9{% if openjdk_app == \"jre\" %}-jre{% endif %}"),
      } of String => JSON::Any
      sub = Krikri::VarSubstitutor.new(vars: v)
      sub.substitute("{{ openjdk_install_subdir }}", strict: true).should contain("-jre")
    end

    it "does not false-positive on is defined tests" do
      v = {
        "ssl_protocols" => JSON::Any.new("TLSv1.2"),
      } of String => JSON::Any
      sub = Krikri::VarSubstitutor.new(vars: v)
      sub.substitute("{% if ssl_protocols is defined %}use-{{ ssl_protocols }}{% endif %}", strict: true).should eq("use-TLSv1.2")
    end

    it "does not false-positive on for-loop variables" do
      v = {
        "items" => JSON.parse(%(["a", "b"])),
      } of String => JSON::Any
      sub = Krikri::VarSubstitutor.new(vars: v)
      # The loop var `item` is not in @vars, but must not be flagged.
      sub.substitute("{% for item in items %}{{ item }}{% endfor %}", strict: true).should eq("ab")
    end

    it "does not false-positive on string literals inside the condition" do
      v = {
        "mode" => JSON::Any.new("0644"),
      } of String => JSON::Any
      sub = Krikri::VarSubstitutor.new(vars: v)
      sub.substitute("{% if mode == \"0644\" %}ok{% endif %}", strict: true).should eq("ok")
    end

    it "non-strict render still treats undefined-in-if as falsy (no false-negative)" do
      v = {
        "openjdk_install_dir" => JSON::Any.new("/usr/local/openjdk"),
      } of String => JSON::Any
      sub = Krikri::VarSubstitutor.new(vars: v)
      # Lenient path unchanged: undefined == \"jre\" is falsy, no raise.
      sub.substitute("{{ openjdk_install_dir }}/{% if openjdk_app == \"jre\" %}-jre{% endif %}", strict: false).should eq("/usr/local/openjdk/")
    end

    it "does not raise when an undefined ref inside {% if %} is piped through | default(...)" do
      # Found via geerlingguy.mysql's own vars/setup-Debian.yml:
      # `deb_mysql_python_package: "{% if 'python3' in
      # ansible_python_interpreter|default('') %}python3-mysqldb{% else
      # %}python-mysqldb{% endif %}"`. Real Jinja2's `default` filter
      # exists specifically to suppress Undefined - `x | default(y)`
      # never raises regardless of x's own definedness, even under a
      # strict environment. This scan previously only carved out an
      # identifier BEING a filter's own name (preceded by `|`), not an
      # identifier immediately FOLLOWED by `| default(...)` - the far
      # more common real shape, and the one this idiom uses.
      v = {} of String => JSON::Any
      sub = Krikri::VarSubstitutor.new(vars: v)
      sub.substitute(
        %({% if 'python3' in ansible_python_interpreter|default('') %}python3-mysqldb{% else %}python-mysqldb{% endif %}),
        strict: true
      ).should eq("python-mysqldb")
    end

    it "still raises for an undefined ref inside {% if %} with NO default() filter" do
      # Same shape as the openjdk case above, phrased as a direct
      # regression check that the new default()-carve-out doesn't
      # accidentally swallow the general case too.
      v = {} of String => JSON::Any
      sub = Krikri::VarSubstitutor.new(vars: v)
      expect_raises(Krikri::UndefinedVariableError, /'some_var' is undefined/) do
        sub.substitute("{% if some_var == \"x\" %}yes{% endif %}", strict: true)
      end
    end
  end
end
