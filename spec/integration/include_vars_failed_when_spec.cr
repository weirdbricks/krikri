require "../spec_helper"

# Real Ansible's own failed_when: override applies to include_vars:'s OWN
# file-not-found failure - the include_vars action's failure is an ordinary
# task result dict run through the same failed_when: evaluation as any
# module result. Verified live against ansible-core 2.19:
# `include_vars: {file: missing.yml}, failed_when: false` shows the task
# as plain `ok` (recap ok+=1 - NOT `ignored`, unlike ignore_errors:),
# defines the `name:` var as an empty hash, and the play continues; the
# same missing file with failed_when: true (or omitted) still halts as
# fatal. Found via round900991/900994 practical-ansible.nginx_docker/
# nginx_project: both roles' `include_vars: {file: package.json, name:
# npm}` + `failed_when: false` (the file belongs to the consumer project,
# not the role) halted this engine's play unconditionally - twice over,
# because the dedicated include_vars task parser never parsed failed_when:
# in the first place.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("include-vars-failed-when", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "failed_when: on include_vars:'s own file-not-found failure" do
  it "failed_when: false on a missing file does not halt the play and the task is ok, not failed" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include vars that dont exist, allowed to fail
            include_vars:
              file: "/nonexistent/does-not-exist-#{Random.rand(1_000_000)}.yml"
            failed_when: false
          - name: still runs after
            debug:
              msg: still going
      YAML

    status.success?.should be_true
    output.should contain("still going")
    output.should match(/ok=2\b/)
    output.should match(/failed=0\b/)
    output.should match(/ignored=0\b/)
  end

  it "failed_when: false also defines the name: var as an empty hash, like real Ansible" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include vars that dont exist, allowed to fail
            include_vars:
              file: "/nonexistent/does-not-exist-#{Random.rand(1_000_000)}.yml"
              name: npm
            failed_when: false
          - name: probe
            debug:
              msg: "npm defined={{ npm is defined }}"
      YAML

    status.success?.should be_true
    output.should contain("npm defined=True")
  end

  it "failed_when: true on a missing file still hard-fails and halts" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include vars that dont exist, forced failure
            include_vars:
              file: "/nonexistent/does-not-exist-#{Random.rand(1_000_000)}.yml"
            failed_when: true
          - name: should not run
            debug:
              msg: SHOULD_NOT_RUN
      YAML

    status.success?.should be_false
    output.should_not contain("SHOULD_NOT_RUN")
    output.should match(/failed=1\b/)
  end

  it "a missing file with no failed_when: at all still hard-fails and halts" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: include vars that dont exist, default failure
            include_vars:
              file: "/nonexistent/does-not-exist-#{Random.rand(1_000_000)}.yml"
          - name: should not run
            debug:
              msg: SHOULD_NOT_RUN
      YAML

    status.success?.should be_false
    output.should_not contain("SHOULD_NOT_RUN")
    output.should match(/failed=1\b/)
  end
end
