require "../spec_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-two-local-hosts.ini")

describe "ansible_version magic var" do
  it "is a real {full, major, minor, revision, string} dict, not undefined" do
    # Real bug found re-benchmarking xanmanning.k3s (round 163 regression
    # check, right after 0.9.517 made module-arg templating strict for
    # bare variable references): `ansible_version` was entirely
    # unimplemented. The role's own pre_checks.yml gates its VERY FIRST
    # real task on `ansible_version.string is version_compare(k3s_
    # ansible_min_version, '>=')` - a bare dotted lookup that always
    # resolved to this engine's "undefined" sentinel. Before 0.9.517 this
    # silently mis-evaluated the comparison (masking the gap); after
    # 0.9.517 it hard-failed the task outright ("'ansible_version.string'
    # is undefined") - a real regression surfaced by a real fix, not
    # caused by it. Real ansible-core reports its own controller version
    # here (verified live: {"full": "2.19.4", "major": 2, "minor": 19,
    # "revision": 4, "string": "2.19.4"} against ansible-core 2.19.4) -
    # this engine deliberately reports a fixed real ansible-core version
    # rather than its own "0.9.x" project version, since every
    # version-gated role feature in the wild expects a 2.x-shaped
    # comparison target.
    playbook = File.tempname("ansible-version", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: all
        gather_facts: false
        vars:
          k3s_ansible_min_version: "2.11"
        tasks:
          - name: version check idiom
            ansible.builtin.assert:
              that:
                - ansible_version.string is version_compare(k3s_ansible_min_version, '>=')
              fail_msg: "Ansible v{{ ansible_version.string }} is not supported."
              success_msg: "Ansible v{{ ansible_version.string }} is supported."
          - name: show full dict
            ansible.builtin.debug:
              msg: "{{ ansible_version.major }}.{{ ansible_version.minor }}.{{ ansible_version.revision }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("is supported")
    output.to_s.should_not contain("is undefined")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
