require "../spec_helper"
require "../../src/crystal_play/variable_substitutor"

# Regression cover for the 0.9.79 performance work: the Crinja environment
# is now shared process-wide, the JSON::Any -> Crinja::Value conversion is
# memoized per renderer, and VarSubstitutor builds its evaluator/renderer
# lazily. All three are only safe if nothing leaks between renders or
# survives a set_variable, which is what these assert.
private def vars_of(pairs : Hash(String, String)) : Hash(String, JSON::Any)
  result = Hash(String, JSON::Any).new
  pairs.each { |key, value| result[key] = JSON::Any.new(value) }
  result
end

describe CrystalPlay::VarSubstitutor do
  describe "shared Crinja environment" do
    it "keeps two substitutors with different variable sets independent" do
      first = CrystalPlay::VarSubstitutor.new(vars: vars_of({"name" => "alpha"}), host_name: "h1")
      second = CrystalPlay::VarSubstitutor.new(vars: vars_of({"name" => "beta"}), host_name: "h2")

      template = "{% if name %}{{ name }}{% endif %}"

      first.substitute(template).should eq("alpha")
      second.substitute(template).should eq("beta")
      # Re-render the first one *after* the second has used the shared
      # environment - a leaked context would show "beta" here.
      first.substitute(template).should eq("alpha")
    end

    it "does not leak a top-level {% set %} from one render into the next" do
      subject = CrystalPlay::VarSubstitutor.new(vars: vars_of({"base" => "x"}), host_name: "h")

      subject.substitute("{% set leaked = 'yes' %}{{ base }}").should eq("x")
      # `leaked` was only ever bound in the previous render's scope.
      # (Note the `{{ }}`: substitute only reaches the Crinja path at all
      # for text containing one, so the else-branch carries it.)
      subject.substitute("{% if leaked is defined %}LEAK{% else %}{{ base }}{% endif %}").should eq("x")
    end

    it "renders a {% for %} loop identically on repeated calls" do
      subject = CrystalPlay::VarSubstitutor.new(vars: vars_of({"sep" => "-"}), host_name: "h")
      template = "{% for i in [1, 2, 3] %}{{ i }}{{ sep }}{% endfor %}"

      first = subject.substitute(template)
      first.should eq("1-2-3-")
      subject.substitute(template).should eq(first)
    end
  end

  describe "#set_variable" do
    it "is visible to the plain {{ }} path after lazy construction" do
      subject = CrystalPlay::VarSubstitutor.new(vars: vars_of({"a" => "1"}), host_name: "h")

      subject.substitute("{{ a }}").should eq("1")
      subject.set_variable("a", "2")
      subject.substitute("{{ a }}").should eq("2")
    end

    it "invalidates the renderer's memoized variable conversion" do
      subject = CrystalPlay::VarSubstitutor.new(vars: vars_of({"a" => "1"}), host_name: "h")
      template = "{% if a %}{{ a }}{% endif %}"

      # Force the renderer to build and memoize its converted vars first,
      # so the set_variable below has something stale to invalidate.
      subject.substitute(template).should eq("1")
      subject.set_variable("a", "2")
      subject.substitute(template).should eq("2")
    end

    it "is visible when set before anything has been substituted at all" do
      subject = CrystalPlay::VarSubstitutor.new(vars: vars_of({"a" => "1"}), host_name: "h")

      subject.set_variable("b", "new")
      subject.substitute("{{ b }}").should eq("new")
      subject.substitute("{% if b %}{{ b }}{% endif %}").should eq("new")
    end
  end

  describe "lazy component construction" do
    it "still returns literal text untouched without building anything" do
      subject = CrystalPlay::VarSubstitutor.new(vars: vars_of({"a" => "1"}), host_name: "h")
      subject.substitute("no placeholders here").should eq("no placeholders here")
    end

    it "still exposes magic variables" do
      subject = CrystalPlay::VarSubstitutor.new(vars: vars_of({} of String => String), host_name: "web1")
      subject.substitute("{{ inventory_hostname }}").should eq("web1")
    end
  end

  describe "re-templating a value that is itself more Jinja" do
    it "re-renders a variable's own value through the full Crinja pipeline when it contains block tags, not just {{ }}" do
      # Real bug found benchmarking githubixx.ansible_role_wireguard:
      # `wireguard_remote_directory`'s own default value is a multi-line
      # `{%- if ... -%}...{%- elif ... -%}...{%- endif -%}` block (no
      # `{{ }}` inside at all). A task param like `dest: "{{
      # wireguard_remote_directory }}/{{ wireguard_conf_filename }}"`
      # fetched that raw block-tag text as a plain string - format_value
      # doesn't template it - and the outer re-pass loop only ever
      # checked for leftover "{{", never "{%"/"{#", so it never got a
      # second pass to actually evaluate the block. The literal,
      # unparsed "{%- if ... %}" text became the real `dest:` path.
      v = Hash(String, JSON::Any).new
      v["use_netplan"] = JSON::Any.new(false)
      v["remote_dir"] = JSON::Any.new(<<-JINJA.strip)
        {%- if use_netplan -%}
        /etc/netplan
        {%- else -%}
        /etc/wireguard
        {%- endif -%}
        JINJA
      v["conf_filename"] = JSON::Any.new("wg0.conf")
      subject = CrystalPlay::VarSubstitutor.new(vars: v, host_name: "h")

      result = subject.substitute("{{ remote_dir }}/{{ conf_filename }}")
      result.should_not contain("{%")
      result.should contain("/etc/wireguard")
      result.should contain("wg0.conf")
    end
  end
end
