require "../minitest_helper"

# The skipped-banner shape for tasks inside a block: whose own when: was
# False. Pinned line-for-line against a real ansible-playbook 2.19.11 run
# of the same playbooks: the block-inherited condition is evaluated per
# loop item, so a LOOPED child prints ONE `skipping: [host] => (item=...)`
# line per item plus the usual bare trailing `skipping: [host]` line -
# not the single bare line a non-looped child gets. A loop source that
# resolves to zero items collapses to the bare line, and one that cannot
# resolve at all (undefined variable) collapses to it too - real never
# fails a task on its loop source once the inherited when: is already
# False. rescue: children of a skipped block print nothing (the block can
# not have failed); always: children print like block: children.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, extra_args : Array(String) = [] of String) : String
  playbook = File.tempname("block-skip-banner", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, extra_args + ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true)
  output.to_s
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "skipped-block banner shapes (block: when: false)" do
  it "prints one skipping line per loop item plus the bare trailing line for a looped child" do
    output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        vars:
          go: false
        tasks:
          - when: go
            block:
              - name: looped include in block
                loop: [ca, cert, key]
                loop_control:
                  loop_var: k
                include_tasks: does-not-matter.yml
              - name: plain loop in skipped block
                ansible.builtin.debug:
                  msg: "item {{ item }}"
                loop: [x, y]
      YAML

    lines = output.lines
    idx = lines.index { |line| line.starts_with?("TASK [looped include in block]") }.not_nil!
    # The per-item lines carry a trailing space (the empty -v dump slot),
    # exactly like real's.
    lines[idx + 1].must_equal("skipping: [localhost] => (item=ca) ")
    lines[idx + 2].must_equal("skipping: [localhost] => (item=cert) ")
    lines[idx + 3].must_equal("skipping: [localhost] => (item=key) ")
    lines[idx + 4].must_equal("skipping: [localhost]")
    idx = lines.index { |line| line.starts_with?("TASK [plain loop in skipped block]") }.not_nil!
    lines[idx + 1].must_equal("skipping: [localhost] => (item=x) ")
    lines[idx + 2].must_equal("skipping: [localhost] => (item=y) ")
    lines[idx + 3].must_equal("skipping: [localhost]")
    # One skipped per TASK, not per item.
    output.must_match(/skipped=2 /)
  end

  it "keeps rescue: children silent and prints always: children under a skipped block" do
    output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        vars:
          go: false
        tasks:
          - when: go
            block:
              - name: normal child
                ansible.builtin.debug:
                  msg: normal
              - block:
                  - name: failing child
                    ansible.builtin.fail:
                      msg: boom
                rescue:
                  - name: rescue looped
                    ansible.builtin.debug:
                      msg: "rescue {{ item }}"
                    loop: [r1, r2]
                always:
                  - name: always looped
                    ansible.builtin.debug:
                      msg: "always {{ item }}"
                    loop: [a1, a2]
      YAML

    output.must_include("TASK [normal child] ")
    output.must_include("TASK [failing child] ")
    output.must_include("TASK [always looped] ")
    output.must_include("skipping: [localhost] => (item=a1) ")
    output.must_include("skipping: [localhost] => (item=a2) ")
    output.must_include("skipping: [localhost]\n")
    # rescue: children of a never-run block are never shown at all.
    output.wont_include("rescue looped")
    output.wont_include("(item=r1)")
    output.must_match(/skipped=3 /)
  end

  it "renders loop_control.label on the skipped per-item lines" do
    output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        vars:
          go: false
        tasks:
          - when: go
            block:
              - name: labeled loop
                ansible.builtin.debug:
                  msg: "{{ item.name }}"
                loop:
                  - {name: n1}
                  - {name: n2}
                loop_control:
                  label: "LBL-{{ item.name }}"
      YAML

    output.must_include("skipping: [localhost] => (item=LBL-n1) ")
    output.must_include("skipping: [localhost] => (item=LBL-n2) ")
    output.scan("skipping: [localhost]").size.must_equal(3)
  end

  it "collapses an empty loop source and an undefined loop source to the single bare line" do
    output = run_playbook(<<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        vars:
          go: false
          empty_list: []
        tasks:
          - when: go
            block:
              - name: empty templated loop
                ansible.builtin.debug:
                  msg: "{{ item }}"
                loop: "{{ empty_list }}"
              - name: undefined loop source
                ansible.builtin.debug:
                  msg: "{{ item }}"
                loop: "{{ totally_undefined_var }}"
      YAML

    lines = output.lines
    lines.count { |line| line == "skipping: [localhost]" }.must_equal(2)
    output.wont_include("(item=")
    output.must_match(/skipped=2 /)
  end

  it "prints the role-prefixed per-item banners for a skipped role (roles: with when:)" do
    role_dir = File.tempname("block-skip-banner-role")
    Dir.mkdir(role_dir)
    Dir.mkdir(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "tasks", "main.yml"), <<-YAML)
      - name: role looped task
        ansible.builtin.debug:
          msg: "role item {{ item }}"
        loop: [r1, r2]
    YAML
    playbook = File.tempname("block-skip-banner-role-play", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        vars:
          go: false
        roles:
          - role: #{role_dir}
            when: go
    YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.must_equal(true)
    output.to_s.must_include("role looped task]")
    output.to_s.must_include("skipping: [localhost] => (item=r1) ")
    output.to_s.must_include("skipping: [localhost] => (item=r2) ")
    output.to_s.must_include("skipping: [localhost]\n")
    output.to_s.must_match(/skipped=1 /)
  ensure
    FileUtils.rm_rf(role_dir) if role_dir
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "prints per-item banners for a looped include_tasks: under a skipped block, and nothing for the included file's own tasks" do
    include_file = File.tempname("block-skip-banner-include", ".yml")
    File.write(include_file, <<-YAML)
      - name: included looped
        ansible.builtin.debug:
          msg: "{{ item }}"
        loop: [c1, c2]
    YAML
    playbook = File.tempname("block-skip-banner-include-play", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        vars:
          go: false
        tasks:
          - when: go
            block:
              - name: plain include
                include_tasks: #{include_file}
              - name: looped include
                include_tasks: #{include_file}
                loop: [i1, i2]
    YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    status.success?.must_equal(true)
    output.to_s.must_include("TASK [plain include] ")
    output.to_s.must_include("skipping: [localhost]\n")
    output.to_s.must_include("skipping: [localhost] => (item=i1) ")
    output.to_s.must_include("skipping: [localhost] => (item=i2) ")
    # The include never ran, so its file's own tasks never appear.
    output.to_s.wont_include("TASK [included looped]")
    output.to_s.must_match(/skipped=2 /)
  ensure
    File.delete(include_file) if include_file && File.exists?(include_file)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "prints the same per-item banners in check mode" do
    yaml = <<-YAML
      - name: repro
        hosts: localhost
        gather_facts: false
        connection: local
        vars:
          go: false
        tasks:
          - when: go
            block:
              - name: plain loop in skipped block
                ansible.builtin.debug:
                  msg: "item {{ item }}"
                loop: [x, y]
      YAML
    output = run_playbook(yaml, extra_args: ["--check"])

    output.must_include("skipping: [localhost] => (item=x) ")
    output.must_include("skipping: [localhost] => (item=y) ")
    output.must_include("skipping: [localhost]\n")
  end
end
