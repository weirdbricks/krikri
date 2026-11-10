require "../minitest_helper"
require "file_utils"

# wait_for_connection's check mode is gated inside its own ACTION plugin
# (ansible-core's plugins/action/wait_for_connection.py returns
# dict(skipped=True) under check mode) - before the option rejection that
# fires outside check mode, but AFTER the plugin's int() conversions of the
# four numeric args. krikri used to run its action-level "Invalid options"
# check first, so a typo'd option failed the task under --check where Ansible
# skips (issue #1084, live-verified vs ansible-core 2.21.6).
private PROJECT_ROOT_WFC_CM = File.expand_path("../..", __DIR__)
private BINARY_WFC_CM       = File.join(PROJECT_ROOT_WFC_CM, "bin", "krikri-playbook")
private INVENTORY_WFC_CM    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def wfc_cm_playbook(yaml : String, args : Array(String) = [] of String)
  playbook = File.tempname("wait-for-connection-check-mode", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY_WFC_CM, ["-i", INVENTORY_WFC_CM, playbook] + args, output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "wait_for_connection check mode action skip" do
  it "skips a typo'd option under --check instead of failing Invalid options" do
    status, output = wfc_cm_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: typo'd option
            ansible.builtin.wait_for_connection:
              delay: "0"
              timeout: "5"
              slepe: "1"
            register: kpg_task_0
            ignore_errors: true
          - name: follow-up
            ansible.builtin.debug:
              msg: FOLLOW-UP RAN
            when: kpg_task_0 is not skipped
      YAML

    status.exit_code.must_equal(0)
    output.must_include("skipping: [localhost]")
    output.wont_include("Invalid options")
    output.wont_include("ignoring")
    output.must_include("skipped=2")
  end

  it "registers the bare {changed, failed, skipped} shape under --check" do
    # Ansible's action plugin returns dict(skipped=True) with no msg; the
    # executor backfills changed/failed (live-verified vs 2.21.6 via
    # {{ r.keys() | list | to_json }}).
    status, output = wfc_cm_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: typo'd option
            ansible.builtin.wait_for_connection:
              timeout: "5"
              slepe: "1"
            register: r
            ignore_errors: true
          - name: dump
            ansible.builtin.debug:
              msg: "{{ r | to_json }}"
      YAML

    status.exit_code.must_equal(0)
    output.must_include("skipping: [localhost]")
    output.must_include(%q(\"changed\": false, \"failed\": false, \"skipped\": true))
  end

  it "still fails a non-numeric numeric arg under --check" do
    # int() runs BEFORE the check-mode return in Ansible's action plugin.
    status, output = wfc_cm_playbook(<<-YAML, ["--check"])
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: non-numeric delay
            ansible.builtin.wait_for_connection:
              delay: zayose
            ignore_errors: true
      YAML

    status.exit_code.must_equal(0)
    output.must_include("invalid literal for int() with base 10: 'zayose'")
    output.wont_include("skipping:")
  end

  it "still fails a typo'd option outside check mode" do
    status, output = wfc_cm_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: typo'd option
            ansible.builtin.wait_for_connection:
              timeout: "5"
              slepe: "1"
            ignore_errors: true
      YAML

    status.exit_code.must_equal(0)
    output.must_include("Invalid options for ansible.builtin.wait_for_connection: slepe")
  end
end
