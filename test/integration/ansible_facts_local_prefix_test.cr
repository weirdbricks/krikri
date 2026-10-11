require "../minitest_helper"

# Round 5460204 - Oefenweb.mydumper, warm phase only: the role's build-skip
# chain (`ansible_facts['ansible_local'] is not defined or ... is version(
# mydumper_version.number, '!=')`) skipped in real ansible-playbook 2.19.11
# (the cold run had already published /etc/ansible/facts.d/mydumper.fact, so
# the warm play-start gather re-read it) but re-ran the whole source build in
# krikri. Root cause: TaskExecutor's ansible_facts dict stripped the ansible_
# prefix from EVERY fact key, but real Ansible keeps ansible_local prefixed
# inside ansible_facts - live-verified against 2.19.11, where a key-listing
# debug shows ansible_local as the ONLY ansible_-prefixed survivor in
# ansible_facts, and `ansible_facts['local']` is undefined. With the key
# stripped to 'local', the chain's first clause was true and the block ran.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : String
  playbook = File.tempname("facts-local-prefix", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true, output.to_s)
  output.to_s
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def build_skip_chain
  [
    "ansible_facts['ansible_local'] is not defined",
    "or ansible_facts['ansible_local']['mydumper'] is not defined",
    "or ansible_facts['ansible_local']['mydumper']['version'] is not defined",
    "or ansible_facts['ansible_local']['mydumper']['version']['number'] is not defined",
    "or ansible_facts['ansible_local']['mydumper']['version']['number'] is defined",
    "and ansible_facts['ansible_local']['mydumper']['version']['number'] is version(mydumper_version.number, '!=')",
  ].join(" ")
end

describe "ansible_facts keeps ansible_local prefixed (Oefenweb.mydumper round 5460204)" do
  it "skips the warm build block when the facts.d file already reports the built version" do
    facts_dir = File.tempname("facts-local-prefix-dir")
    Dir.mkdir(facts_dir)
    File.write(File.join(facts_dir, "mydumper.fact"),
      %({"version": {"number": "0.13.1-2"}}\n))
    marker = File.tempname("facts-local-prefix-marker")
    File.delete(marker) if File.exists?(marker)
    playbook_body = <<-YAML
      - name: warm state
        hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mydumper_version:
            number: 0.13.1-2
        tasks:
          - name: gather with fact_path
            ansible.builtin.setup:
              fact_path: #{facts_dir}
          - name: show ansible_local
            ansible.builtin.debug:
              var: ansible_facts['ansible_local']
          - name: build
            when: #{build_skip_chain}
            block:
              - name: create (build) directory
                ansible.builtin.file:
                  path: #{marker}
                  state: touch
                  mode: "0644"
      YAML
    output = run_playbook(playbook_body)
    File.exists?(marker).must_equal(false, "warm build block RAN; the skip chain must be false when the published version matches:\n#{output}")
    output.to_s.must_include("skipping: [localhost]")
    # The fact dict must be reachable under its real (prefixed) key, not
    # a de-prefixed 'local' one.
    output.to_s.must_include(%("number": "0.13.1-2"))
  ensure
    FileUtils.rm_rf(facts_dir) if facts_dir && Dir.exists?(facts_dir)
    File.delete(marker) if marker && File.exists?(marker)
  end

  it "does not expose a de-prefixed 'local' key inside ansible_facts" do
    facts_dir = File.tempname("facts-local-prefix-dir2")
    Dir.mkdir(facts_dir)
    File.write(File.join(facts_dir, "mydumper.fact"),
      %({"version": {"number": "0.13.1-2"}}\n))
    output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gather with fact_path
            ansible.builtin.setup:
              fact_path: #{facts_dir}
          - name: prefixed key defined
            ansible.builtin.debug:
              msg: prefixed-defined
            when: ansible_facts['ansible_local'] is defined
          - name: de-prefixed key undefined
            ansible.builtin.debug:
              msg: local-undefined
            when: ansible_facts['local'] is not defined
      YAML
    lines = output.lines
    idx = lines.index! { |line| line.starts_with?("TASK [prefixed key defined]") }
    lines[idx + 1].must_match(/^ok: /)
    idx = lines.index! { |line| line.starts_with?("TASK [de-prefixed key undefined]") }
    lines[idx + 1].must_match(/^ok: /)
  ensure
    FileUtils.rm_rf(facts_dir) if facts_dir && Dir.exists?(facts_dir)
  end

  it "still runs the build block when no facts.d file reports a version (cold shape)" do
    empty_dir = File.tempname("facts-local-prefix-empty")
    Dir.mkdir(empty_dir)
    marker = File.tempname("facts-local-prefix-marker2")
    File.delete(marker) if File.exists?(marker)
    playbook_body = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          mydumper_version:
            number: 0.13.1-2
        tasks:
          - name: gather with empty fact_path
            ansible.builtin.setup:
              fact_path: #{empty_dir}
          - name: build
            when: #{build_skip_chain}
            block:
              - name: create (build) directory
                ansible.builtin.file:
                  path: #{marker}
                  state: touch
                  mode: "0644"
      YAML
    output = run_playbook(playbook_body)
    File.exists?(marker).must_equal(true, "cold build block was skipped; with no published local facts the chain must be true:\n#{output}\nPLAYBOOK:\n#{playbook_body}")
  ensure
    FileUtils.rm_rf(empty_dir) if empty_dir && Dir.exists?(empty_dir)
    File.delete(marker) if marker && File.exists?(marker)
  end
end
