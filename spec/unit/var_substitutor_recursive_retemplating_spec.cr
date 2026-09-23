require "../spec_helper"
require "../../src/krikri/variable_substitutor"

# Round 191 regression cover (gantsign.helm): recursive re-templating of a
# task argument must apply ONLY to leftover templates that originated in a
# VARIABLE'S OWN VALUE. Real Ansible renders a task argument in a single
# Jinja2 pass; brace text produced by an evaluated QUOTED LITERAL in the
# task itself (helm's Go-template `{{ if .Version }}...{{ else }}...
# {{ end }}` argument) passes through verbatim. The old whole-output re-pass
# loop parsed `{{ else }}` as a Jinja tag and failed with "'else' is
# undefined" while real ansible ran the command fine.
private def jvars(pairs : Hash(String, String)) : Hash(String, JSON::Any)
  result = Hash(String, JSON::Any).new
  pairs.each { |key, value| result[key] = JSON::Any.new(value) }
  result
end

describe Krikri::VarSubstitutor do
  describe "recursive re-templating scope (round 191)" do
    it "leaves Go-template brace text from a quoted task-arg literal verbatim" do
      sub = Krikri::VarSubstitutor.new(vars: jvars({"helm_install_dir" => "/usr/local/bin"}))
      arg = "{{ helm_install_dir }}/helm version --client --template " \
            "{{ \"'{{ if .Version }}{{ .Version }}{{ else }}{{ .Client.SemVer }}{{ end }}'\" }}"
      sub.substitute(arg, strict: true, output: true).should eq \
        "/usr/local/bin/helm version --client --template '{{ if .Version }}{{ .Version }}{{ else }}{{ .Client.SemVer }}{{ end }}'"
    end

    it "still re-templates a variable whose own value is a template" do
      sub = Krikri::VarSubstitutor.new(vars: jvars({
        "mount"      => "{\"mode\": \"{{ os_mode }}\"}",
        "os_mode"    => "0755",
        "inner_task" => "{{ inner_path }}/run.sh",
        "inner_path" => "/opt/bin",
      }))
      # variable-origin: mount.mode's VALUE is itself a template
      sub.substitute("mode={{ mount.mode }}", strict: true, output: true).should eq "mode=0755"
      # and a two-level chain: task ref -> var whose value is another task-shaped ref
      sub.substitute("src={{ inner_task }}", strict: true, output: true).should eq "src=/opt/bin/run.sh"
    end

    it "does not re-template filter-chain output that merely contains brace text" do
      sub = Krikri::VarSubstitutor.new(vars: jvars({"v" => "x"}))
      arg = "{{ 'pre {{literal}} post' }}-{{ v }}"
      sub.substitute(arg, strict: true, output: true).should eq "pre {{literal}} post-x"
    end

    # The 0.9.1268 residual: the re-pass was ALL-OR-NOTHING on the whole
    # rendered text - one qualifying (variable-origin, raw-value-is-
    # template) span re-passed the ENTIRE output through span expansion
    # again, with no memory of which spans were already resolved-and-
    # final. A resolved set_fact value whose stored text is itself brace
    # text shares a string with a YAML-template span -> the re-pass
    # re-scanned the resolved value's `{{ inner_undefined }}` output as
    # another template level and died (strict) on the never-defined
    # inner name - exactly the 0.9.1267 crash the registry carve-out was
    # built to prevent, reopened by the mixed string. Real Ansible
    # renders the whole arg in ONE Jinja2 pass: the YAML-template var
    # re-templates recursively (its own value is rendered as part of
    # resolving it), the resolved fact passes through verbatim.
    it "re-templates only the variable-origin span in a mixed string, leaving a resolved span's brace text verbatim" do
      Krikri::VarSubstitutor.set_resolved_var_names("mixed-span-host", ["resolved_brace_var"])
      sub = Krikri::VarSubstitutor.new(
        vars: jvars({
          "resolved_brace_var" => "{{ inner_undefined }}",
          "yaml_template_var"  => "{{ another_var }}",
          "another_var"        => "final",
        }),
        host_name: "mixed-span-host",
      )
      sub.substitute("{{ resolved_brace_var }} and {{ yaml_template_var }}", strict: true, output: true)
        .should eq "{{ inner_undefined }} and final"
    end
  end

  # 0.9.1267 gap (perf benchmark's Jinja edge-case section, live-verified
  # against real ansible-core 2.19.11): a set_fact:/register: value whose
  # stored TEXT contains `{{ ... }}` is RESOLVED - real Ansible tags it
  # and never re-scans it, while the content-based re-pass treated the
  # brace text as another template level and died on the inner
  # never-defined name as an unhandled controller crash.
  describe "resolved-value pass-through" do
    it "never re-templates a name published as execution-resolved" do
      Krikri::VarSubstitutor.set_resolved_var_names("resolved-host", ["x"])
      sub = Krikri::VarSubstitutor.new(
        vars: jvars({"x" => "{{ inner_undefined_name }}"}),
        host_name: "resolved-host",
      )
      sub.substitute("value=[{{ x }}]", strict: true, output: true)
        .should eq "value=[{{ inner_undefined_name }}]"
    end

    it "never re-templates a resolved name reached through dotted access" do
      Krikri::VarSubstitutor.set_resolved_var_names("resolved-host", ["probe"])
      vars = {
        "probe"    => JSON.parse("{\"stdout\": \"{{ inner_undefined_name }}\"}"),
        "other"    => JSON.parse("{\"mode\": \"{{ dir_mode }}\"}"),
        "dir_mode" => JSON::Any.new("2750"),
      }
      sub = Krikri::VarSubstitutor.new(vars: vars, host_name: "resolved-host")
      sub.substitute("stdout=[{{ probe.stdout }}]", strict: true, output: true)
        .should eq "stdout=[{{ inner_undefined_name }}]"
      sub.substitute("mode={{ other.mode }}", strict: true, output: true)
        .should eq "mode=2750"
    end

    it "still re-templates a YAML-defined vars: default whose value is a template" do
      sub = Krikri::VarSubstitutor.new(
        vars: jvars({
          "mount"    => "{\"mode\": \"{{ dir_mode }}\"}",
          "dir_mode" => "2750",
        }),
        host_name: "yaml-host",
      )
      sub.substitute("mode={{ mount.mode }}", strict: true, output: true).should eq "mode=2750"
    end
  end
end
