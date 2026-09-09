require "file_utils"
require "../spec_helper"

# Runs the compiled binary against real playbooks: the TASK[...] banner text
# for tasks reached through a LOOPED include_tasks: is entirely a display-time
# concern in executor_blocks_includes.cr / executor_run_loop.cr - not reachable
# from a unit spec.
#
# Found benchmarking systemli.jitsi_meet (round 74501): its apt_repositories
# dependency includes tasks/repo.yml with `loop: "{{ apt_repositories }}"`,
# and repo.yml's own earlier set_fact: tasks define the `_name` that later
# tasks in the SAME iteration reference in their `name:` ("Add key by content
# for {{ _name }}"). The old eager name-substitution pass baked every included
# task's name ONCE at include-entry time - before any of those set_fact: tasks
# had run - so every iteration's banner showed a permanent "... for undefined"
# even though the same task's module params (rendered lazily at execution)
# resolved correctly. Real ansible-core 2.19.4 templates each task's name at
# ITS OWN task-start with current task_vars, so the banner shows the real
# per-iteration value.
describe "TASK banner names of tasks inside a looped include_tasks:" do
  it "renders each iteration's name from facts set earlier in that same iteration (not a baked 'undefined')" do
    src_dir = File.tempname("looped-include-task-name")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(File.join(src_dir, "repo.yml"), <<-YAML)
      - name: derive the name fact for {{ item.key_url }}
        ansible.builtin.set_fact:
          _name: "{{ item.key_url }}"

      - name: "add key by content for {{ _name }}"
        ansible.builtin.debug:
          msg: "key for {{ _name }}"

      - name: "add repo {{ _name }}"
        ansible.builtin.debug:
          msg: "repo for {{ _name }}"
      YAML
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          apt_repositories:
            - key_url: packages.prosody.im
            - key_url: download.jitsi.org
        tasks:
          - name: configure repo
            ansible.builtin.include_tasks: repo.yml
            loop: "{{ apt_repositories }}"
      YAML

    output = IO::Memory.new
    status = Process.run(
      File.join(File.expand_path("../..", __DIR__), "bin", "krikri-playbook"),
      [playbook],
      output: output, error: output, chdir: src_dir
    )

    status.success?.should be_true
    body = output.to_s
    body.should contain("TASK [derive the name fact for packages.prosody.im]")
    body.should contain("TASK [add key by content for packages.prosody.im]")
    body.should contain("TASK [add repo packages.prosody.im]")
    body.should contain("TASK [derive the name fact for download.jitsi.org]")
    body.should contain("TASK [add key by content for download.jitsi.org]")
    body.should contain("TASK [add repo download.jitsi.org]")
    # Neither a baked "undefined" nor the raw unrendered template may leak
    # into any banner - and the name must match what the same task's own
    # module params resolved to for that iteration (the msg lines above).
    body.should_not contain("TASK [add key by content for undefined]")
    body.should_not contain("TASK [add repo undefined]")
    body.should_not contain("TASK [add key by content for {{ _name }}]")
    body.should contain("key for packages.prosody.im")
    body.should contain("repo for download.jitsi.org")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "renders a name referencing the include's own loop item directly, for every iteration" do
    src_dir = File.tempname("looped-include-item-name")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(File.join(src_dir, "inner.yml"), <<-YAML)
      - name: "{{ item.label }} thing"
        ansible.builtin.debug:
          msg: "param sees {{ item.label }} too"
      YAML
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          entries:
            - label: alpha
            - label: beta
        tasks:
          - name: loop the include
            ansible.builtin.include_tasks: inner.yml
            loop: "{{ entries }}"
      YAML

    output = IO::Memory.new
    status = Process.run(
      File.join(File.expand_path("../..", __DIR__), "bin", "krikri-playbook"),
      [playbook],
      output: output, error: output, chdir: src_dir
    )

    status.success?.should be_true
    body = output.to_s
    body.should contain("TASK [alpha thing]")
    body.should contain("TASK [beta thing]")
    body.should_not contain("TASK [{{ item.label }} thing]")
    body.should_not contain("TASK [undefined thing]")
    body.should contain("param sees alpha too")
    body.should contain("param sees beta too")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "does not regress a non-looped task's own templated name, inside or outside the include" do
    src_dir = File.tempname("looped-include-item-name-nonlooped")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(File.join(src_dir, "inner.yml"), <<-YAML)
      - name: "{{ greeting }} from the included file"
        ansible.builtin.debug:
          msg: hi
      YAML
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          greeting: hello
          entries: [1]
        tasks:
          - name: "{{ greeting }} from the play"
            ansible.builtin.debug:
              msg: play
          - name: loop the include
            ansible.builtin.include_tasks: inner.yml
            loop: "{{ entries }}"
      YAML

    output = IO::Memory.new
    status = Process.run(
      File.join(File.expand_path("../..", __DIR__), "bin", "krikri-playbook"),
      [playbook],
      output: output, error: output, chdir: src_dir
    )

    status.success?.should be_true
    body = output.to_s
    body.should contain("TASK [hello from the play]")
    body.should contain("TASK [hello from the included file]")
    body.should_not contain("TASK [{{ greeting }}")
    body.should_not contain("TASK [undefined")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
