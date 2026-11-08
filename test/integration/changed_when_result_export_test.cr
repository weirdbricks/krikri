require "../minitest_helper"

# ansible-core 2.21's UnifiedTaskResult exports `changed_when_result` for
# every task that declares changed_when: - the raising path already had
# it (changed_when_error_result_shape_test.cr), but krikri left the key
# off the ordinary success/failure verdicts entirely. Found via issue
# #960's adarnimrod.openwrt-bootstrap run, whose `raw: opkg update` with
# `changed_when: False` dumps the key on its fatal result
# (live-verified vs 2.21.6). Real leaves the loop AGGREGATE without it -
# the verdict lives on each item result - and never evaluates
# changed_when: on a skipped task, so neither gets the key.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("changed-when-result-export", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  output.to_s
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "changed_when_result is exported on every changed_when: verdict" do
  it "carries the verdict on a failed raw task's dumped result" do
    output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: raw whose command does not exist
            raw: krikri-issue-960-not-a-command
            changed_when: False
      YAML

    output.must_include(%({"changed": false, "changed_when_result": false, "msg": "non-zero return code"))
  end

  it "carries the verdict on an ok result and each loop item, never the aggregate" do
    output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped raw
            raw: echo {{ item }}
            loop: [1, 2]
            changed_when: False
            register: looped
          - debug:
              msg: "item: {{ looped.results[0].changed_when_result }}"
          - debug:
              msg: "aggregate: {{ 'changed_when_result' not in looped }}"
          - name: ok raw
            raw: echo hi
            changed_when: True
            register: ok_result
          - debug:
              msg: "ok: {{ ok_result.changed_when_result }}"
      YAML

    output.must_include(%("msg": "item: False"))
    output.must_include(%("msg": "aggregate: True"))
    output.must_include(%("msg": "ok: True"))
  end
end
