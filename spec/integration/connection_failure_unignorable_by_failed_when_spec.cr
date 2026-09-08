require "../spec_helper"
require "file_utils"

# Real bug found benchmarking buluma.checkmk_agent's own "Download
# check_mk_agent installer (deb)" task (`delegate_to: localhost,
# failed_when: false`, inheriting the play's `become: true`): real
# Ansible fails a task outright when `become:` itself can't succeed (no
# module ever ran, so there's nothing for failed_when:/changed_when: to
# reinterpret) - verified live against ansible-core 2.19.4, a `become:`
# needing a sudo password it doesn't have aborts the whole play as
# `fatal:` even with `failed_when: false` set. This engine previously
# routed a become/connection failure through the same PluginResult ->
# failed_when: pipeline as a genuine module result, so `failed_when:
# false` silently suppressed it and the play continued.
#
# Uses an unknown become_user (not a missing sudo password) so the
# failure is deterministic on any machine regardless of its own sudoers
# config.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a become/connection failure is unignorable by failed_when:" do
  it "fails the task and halts the play even with failed_when: false set" do
    playbook = File.tempname("connection-failure-unignorable", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: become a nonexistent user
            command: whoami
            become: true
            become_user: nonexistent_user_xyz_12345
            failed_when: false
            register: r
          - name: should never run
            debug:
              msg: SHOULD_NOT_RUN
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_false
    output.to_s.should_not contain("SHOULD_NOT_RUN")
    output.to_s.should match(/failed=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
