require "file_utils"
require "../minitest_helper"

# Runs the compiled binary against a real role tree: the bug needs the
# role-context resolution of a dynamic `vars[<loop_var>]` with_subelements:
# source (resolve_loop_subelements), not reachable from a unit spec.
#
# Real bug found in round 5250000 (veselahouba.ufw): the role includes
# config_multi_ip.yml once per `ufw_multi_ip_rules.*` var (include_tasks
# loop with loop_var `_ufw_multi_rule`), and the included task loops
# `with_subelements: ["{{ vars[_ufw_multi_rule] }}", "from_ips"]` over the
# role default `ufw_multi_ip_rules: {}` - an empty DICT. parse_list_result
# only saw lists, so the dict shape fell out of the whole loop-resolver
# chain and the task ran once with `item` unbound ("'item' is undefined")
# instead of real's zero iterations (`skipped:`). Real's subelements lookup
# accepts "a dict or a list" and iterates the dict's VALUES - both shapes
# encoded below, verified against ansible-core 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "with_subelements: over a dynamic vars[...] dict source" do
  it "skips (not fails) when the dict source is empty" do
    run_role_subelements(<<-YAML, defaults: "rules: {}\n").must_include("skipping: [localhost]")
      - debug:
          msg: "{{ item.0.name }}"
        with_subelements:
          - "{{ vars[_lr] }}"
          - from_ips
      YAML
  end

  it "iterates a non-empty dict source's values" do
    output = run_role_subelements(<<-YAML, defaults: "rules:\n  web:\n    name: web\n    from_ips: [\"1.2.3.4\"]\n")
      - debug:
          msg: "{{ item.0.name }} {{ item.1 }}"
        with_subelements:
          - "{{ vars[_lr] }}"
          - from_ips
      YAML
    output.must_include(%("msg": "web 1.2.3.4"))
  end

  private def run_role_subelements(sub_tasks : String, defaults : String = "rules: {}\n") : String
    dir = PluginSpecHelper.tmp_path("subelements-vars-dict", Random::Secure.hex(4))
    FileUtils.mkdir_p(File.join(dir, "roles", "r1", "defaults"))
    FileUtils.mkdir_p(File.join(dir, "roles", "r1", "tasks"))
    File.write(File.join(dir, "roles", "r1", "defaults", "main.yml"), defaults)
    File.write(File.join(dir, "roles", "r1", "tasks", "main.yml"),
      <<-YAML
      - include_tasks: sub.yml
        with_items: "{{ lookup('varnames', 'rules.*').split(',') }}"
        loop_control:
          loop_var: _lr
      YAML
    )
    File.write(File.join(dir, "roles", "r1", "tasks", "sub.yml"), sub_tasks)
    File.write(File.join(dir, "site.yml"),
      <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - r1
      YAML
    )

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, File.join(dir, "site.yml")], output: output, error: output)
    output.to_s
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
