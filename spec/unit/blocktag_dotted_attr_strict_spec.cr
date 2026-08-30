require "../spec_helper"
require "../../src/krikri/variable_substitutor"

# P1.1 (FINDINGS_CHECKLIST.md) - round 200, andrewrothstein.traefik.
#
# vars/main.yml defines
#   traefik_install_ver: '{% if traefik_ver.major | int >= 2 %}2{% else %}{{
#     traefik_ver.major }}{% endif %}'
# and a task uses `include_tasks: 'v{{ traefik_install_ver }}.yml'`. Real
# ansible-core 2.19.4 resolves the block-tag value fully and includes
# v2.yml; this engine produced the literal path "vundefined.yml" and failed
# with "Included tasks file not found".
#
# Root cause was NOT a missing re-render in resolve_simple (the layer the
# first fix attempt targeted, reverted because it swallowed the strict
# chain-walk's raise). It was the strict {% %} block-tag undefined scan:
# SCAN_STRICT_BLOCK_TAG_REF matches a dotted/bracketed chain as ONE token,
# and scan_block_tag_refs checked `@vars.has_key?("traefik_ver.major")` -
# a flat key that can never exist - so EVERY {% if %} condition using
# ordinary attribute access on a defined dict/list was reported undefined
# under strict. CrinjaRenderer.convert_var asks exactly that probe
# (`unresolvable_template?`) before handing Crinja a value, so the WHOLE
# variable became Crinja::Undefined and a bare `{{ traefik_install_ver }}`
# rendered the sentinel text.
#
# Every expectation below was verified against real ansible-core 2.19.4:
# `{% if d.attr == 'x' %}` with `d` defined does NOT raise there (a missing
# ATTRIBUTE is a different error class, "has no attribute"); `{% if
# nosuch.attr %}` DOES raise "'nosuch' is undefined" (the root, not the
# chain).
def traefik_vars : Hash(String, JSON::Any)
  h = Hash(String, JSON::Any).new
  h["traefik_ver"] = JSON.parse(%({"major": 2, "minor": 3}))
  h["traefik_install_ver"] = JSON::Any.new("{% if traefik_ver.major | int >= 2 %}2{% else %}{{ traefik_ver.major }}{% endif %}")
  h
end

describe "strict block-tag scan: dotted/bracketed chains resolve by their ROOT" do
  describe "the traefik case itself" do
    it "renders a bare block-tag-valued variable to its real value" do
      sub = Krikri::VarSubstitutor.new(vars: traefik_vars, host_name: "h")
      sub.substitute("{{ traefik_install_ver }}").should eq("2")
    end

    it "renders it inside a larger literal+template string (the include_tasks shape)" do
      sub = Krikri::VarSubstitutor.new(vars: traefik_vars, host_name: "h")
      sub.substitute("v{{ traefik_install_ver }}.yml").should eq("v2.yml")
    end

    it "takes the ELSE branch when the dotted comparison is false" do
      h = traefik_vars
      h["traefik_ver"] = JSON.parse(%({"major": 1, "minor": 3}))
      sub = Krikri::VarSubstitutor.new(vars: h, host_name: "h")
      sub.substitute("{{ traefik_install_ver }}").should eq("1")
    end

    it "no longer marks the variable's own value unresolvable under strict" do
      sub = Krikri::VarSubstitutor.new(vars: traefik_vars)
      sub.unresolvable_template?(traefik_vars["traefik_install_ver"].as_s).should be_false
    end
  end

  describe "attribute access on a DEFINED root is not undefined" do
    it "dotted chain inside {% if %} renders the taken branch (strict)" do
      h = Hash(String, JSON::Any).new
      h["d"] = JSON.parse(%({"attr": "x"}))
      sub = Krikri::VarSubstitutor.new(vars: h, host_name: "h")
      sub.substitute("{% if d.attr == 'x' %}yes{% else %}no{% endif %}", strict: true).should eq("yes")
    end

    it "bracketed chain with a literal key inside {% if %} (strict)" do
      h = Hash(String, JSON::Any).new
      h["mapping"] = JSON.parse(%({"key": 7}))
      sub = Krikri::VarSubstitutor.new(vars: h, host_name: "h")
      sub.substitute("{% if mapping['key'] == 7 %}seven{% else %}other{% endif %}", strict: true).should eq("seven")
    end

    it "a filter chain on a dotted chain stays fine (strict)" do
      h = Hash(String, JSON::Any).new
      h["d"] = JSON.parse(%({"n": 3}))
      sub = Krikri::VarSubstitutor.new(vars: h, host_name: "h")
      sub.substitute("{% if d.n | int >= 2 %}big{% else %}small{% endif %}", strict: true).should eq("big")
    end
  end

  describe "genuine undefined roots still raise (strictness preserved)" do
    it "raises naming the ROOT for a dotted chain rooted at a missing var" do
      sub = Krikri::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")
      expect_raises(Krikri::UndefinedVariableError, /'nosuch' is undefined/) do
        sub.substitute("{% if nosuch.attr == 'x' %}y{% endif %}", strict: true)
      end
    end

    it "still raises for a plain bare undefined ref in {% if %} (round-194 openjdk)" do
      h = Hash(String, JSON::Any).new
      h["openjdk_install_dir"] = JSON::Any.new("/usr/local/openjdk")
      h["openjdk_install_subdir"] = JSON::Any.new("{{ openjdk_install_dir }}/jdk-16.0.1+9{% if openjdk_app == \"jre\" %}-jre{% endif %}")
      sub = Krikri::VarSubstitutor.new(vars: h, host_name: "h")
      expect_raises(Krikri::UndefinedVariableError, /'openjdk_app' is undefined/) do
        sub.substitute("{{ openjdk_install_subdir }}", strict: true)
      end
    end

    it "still raises for a bare ref chain whose innermost name is missing" do
      h = Hash(String, JSON::Any).new
      h["pw"] = JSON::Any.new("{{ mysql_root_password }}")
      sub = Krikri::VarSubstitutor.new(vars: h, host_name: "h")
      expect_raises(Krikri::UndefinedVariableError, /'mysql_root_password' is undefined/) do
        sub.substitute("pw is [{{ pw }}]", strict: true)
      end
    end
  end

  describe "the lenient path is unchanged" do
    it "still renders undefined-in-if as falsy (no false negative)" do
      h = Hash(String, JSON::Any).new
      h["openjdk_install_dir"] = JSON::Any.new("/usr/local/openjdk")
      sub = Krikri::VarSubstitutor.new(vars: h, host_name: "h")
      sub.substitute("{{ openjdk_install_dir }}/{% if openjdk_app == \"jre\" %}-jre{% endif %}", strict: false).should eq("/usr/local/openjdk/")
    end

    it "still answers the lenient sentinel for a bare chain" do
      h = Hash(String, JSON::Any).new
      h["pw"] = JSON::Any.new("{{ mysql_root_password }}")
      sub = Krikri::VarSubstitutor.new(vars: h, host_name: "h")
      sub.substitute("pw is [{{ pw }}]").should eq("pw is [undefined]")
    end
  end
end
