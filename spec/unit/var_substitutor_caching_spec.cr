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

    it "doesn't stack-overflow on a variable whose value mixes {{ }} and {% %}" do
      # Real bug found benchmarking cloudalchemy.grafana's own
      # `grafana_package: "grafana{% if ansible_architecture == 'armv6l'
      # %}-rpi{% endif %}{{ (grafana_version != 'latest') |
      # ternary('=' ~ grafana_version, '') }}"` (vars/debian.yml -
      # unconditional role vars, not a default). CrinjaRenderer#
      # prepare_crinja_vars pre-renders any `{{`-containing value via a
      # *fresh* VarSubstitutor (documented there as safe since it "can't
      # recurse back into this same render" - true only when the value
      # contains `{{` alone). A value with BOTH `{{` and a block tag
      # escalates straight to renderer.render, which calls
      # prepare_crinja_vars again on the same @vars, building *another*
      # fresh VarSubstitutor for the same still-unrendered value,
      # forever - crashed the whole engine with a stack overflow instead
      # of failing one task.
      #
      # The guarantee this asserts is termination without a crash, not
      # full resolution: the fix is a process-wide recursion-depth cap
      # (MAX_BLOCK_TAG_ESCALATION_DEPTH), which turns unbounded
      # recursion into a bounded one that returns the raw, still-
      # unrendered text once the cap is hit rather than segfaulting -
      # verified separately, against the full engine with a realistic
      # vars_context (many more magic vars than this minimal 3-key one),
      # to actually converge to the correct "grafana" rather than
      # hitting the cap; a bare, hand-built vars hash this small doesn't
      # reliably reach the same convergence path.
      v = Hash(String, JSON::Any).new
      v["ansible_architecture"] = JSON::Any.new("x86_64")
      v["grafana_version"] = JSON::Any.new("latest")
      v["grafana_package"] = JSON::Any.new(
        %(grafana{% if ansible_architecture == 'armv6l' %}-rpi{% endif %}{{ (grafana_version != 'latest') | ternary('=' ~ grafana_version, '') }})
      )
      subject = CrystalPlay::VarSubstitutor.new(vars: v, host_name: "h")

      result = subject.substitute("{{ grafana_package }}")
      result.should_not be_nil
      result.starts_with?("grafana").should be_true
    end
  end

  describe "block-tag-only task params (no {{ }} anywhere)" do
    it "renders {% %} block tags even when the whole span has no {{ }} at all" do
      # Real bug found benchmarking prometheus.prometheus._common's own
      # vars/main.yml: `_common_dependencies: "{% if (...) %}{{ (...)
      # }}{% else %}{% endif %}"` - substitute()'s own top-level guard
      # only ever checked for "{{" before doing ANY work, so a value
      # that's pure block-tag Jinja with the {{ }} interpolation nested
      # inside (only reachable via a variable lookup returning this raw
      # text, not visible at the outer text's own top level) short-
      # circuited immediately, never reaching Crinja at all.
      subject = CrystalPlay::VarSubstitutor.new(vars: vars_of({"pkg_mgr" => "apt"}), host_name: "h")

      subject.substitute("x={% if pkg_mgr == 'apt' %}YES{% else %}NO{% endif %}").should eq("x=YES")
    end
  end

  describe "expression-tag whitespace-trim markers" do
    it "strips a trailing '-' trim marker instead of corrupting the expression into a dangling operator" do
      # Real bug: `{{ 'x' -}}` (no surrounding {% %} block tags, so this
      # goes through the plain mustache-span scanner, not Crinja) passed
      # the trim marker straight into the expression body as literal
      # text ("'x'-"), which then evaluated as a dangling arithmetic
      # minus operator, rendering "undefined" instead of "x".
      subject = CrystalPlay::VarSubstitutor.new(vars: Hash(String, JSON::Any).new, host_name: "h")

      subject.substitute("a{{ 'x' -}}b").should eq("axb")
      subject.substitute("a{{- 'x' }}b").should eq("axb")
    end
  end
end
