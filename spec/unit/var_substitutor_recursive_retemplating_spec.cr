require "../spec_helper"
require "../../src/crystal_play/variable_substitutor"

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

describe CrystalPlay::VarSubstitutor do
  describe "recursive re-templating scope (round 191)" do
    it "leaves Go-template brace text from a quoted task-arg literal verbatim" do
      sub = CrystalPlay::VarSubstitutor.new(vars: jvars({"helm_install_dir" => "/usr/local/bin"}))
      arg = "{{ helm_install_dir }}/helm version --client --template " \
            "{{ \"'{{ if .Version }}{{ .Version }}{{ else }}{{ .Client.SemVer }}{{ end }}'\" }}"
      sub.substitute(arg, strict: true, output: true).should eq \
        "/usr/local/bin/helm version --client --template '{{ if .Version }}{{ .Version }}{{ else }}{{ .Client.SemVer }}{{ end }}'"
    end

    it "still re-templates a variable whose own value is a template" do
      sub = CrystalPlay::VarSubstitutor.new(vars: jvars({
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
      sub = CrystalPlay::VarSubstitutor.new(vars: jvars({"v" => "x"}))
      arg = "{{ 'pre {{literal}} post' }}-{{ v }}"
      sub.substitute(arg, strict: true, output: true).should eq "pre {{literal}} post-x"
    end
  end
end
