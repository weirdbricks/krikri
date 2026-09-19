require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "ansible_ssh_user/ansible_ssh_host/ansible_ssh_port legacy aliases" do
  it "resolves the deprecated ansible_ssh_* spelling to whatever the canonical ansible_* var holds" do
    # Real bug found benchmarking round168's geerlingguy.phergie on
    # Ubuntu 22.04: `defaults/main.yml` sets `phergie_user: "{{
    # ansible_ssh_user }}"` (real Ansible's variable manager treats
    # ansible_ssh_user as a deprecated-but-still-honored alias of
    # ansible_user) - this engine only ever populated the canonical
    # ansible_user spelling (naturally, since that's the literal
    # inventory var name in the common case), so ansible_ssh_user
    # resolved to nothing, rendering the literal "undefined" text
    # wherever a role's own default referenced it - here, `file: {owner:
    # "{{ phergie_user }}"}` failed with "chown failed: failed to look
    # up user undefined".
    inventory = File.tempname("ansible-ssh-user-inv", ".ini")
    File.write(inventory, "node ansible_connection=local ansible_user=root\n")

    playbook = File.tempname("ansible-ssh-user", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: all
        gather_facts: false
        tasks:
          - name: show it
            ansible.builtin.debug:
              msg: "ansible_user={{ ansible_user }} ansible_ssh_user={{ ansible_ssh_user }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
    status.success?.should be_true
    output.to_s.should contain("ansible_user=root ansible_ssh_user=root")
    output.to_s.should_not contain("is undefined")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "still resolves the alias in a looped task's own argument templating" do
    # The other half of the round900321 scoping fix: the alias-free
    # snapshot applies to loop-SOURCE resolution only - a task ARG that
    # references ansible_ssh_user (even on a looped task, where args are
    # templated per item against the full context) must keep resolving,
    # exactly as real ansible-playbook does (live-verified).
    inventory = File.tempname("ansible-ssh-user-inv", ".ini")
    File.write(inventory, "node ansible_connection=local ansible_user=root\n")

    playbook = File.tempname("ansible-ssh-user-loop-arg", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: all
        gather_facts: false
        tasks:
          - name: show it
            ansible.builtin.debug:
              msg: "user={{ ansible_ssh_user }} item={{ item }}"
            loop: [1, 2]
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
    status.success?.should be_true
    output.to_s.should contain("user=root item=1")
    output.to_s.should contain("user=root item=2")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails a loop: source list referencing the alias (real Ansible's scoping)" do
    # round900321 f500.bashrc, live-verified against real ansible-playbook:
    # `loop: ["{{ ansible_ssh_user }}"]` with only ansible_user set is a
    # HARD task failure ("'ansible_ssh_user' is undefined") - real
    # Ansible's loop-source resolution renders against a vars snapshot
    # that never saw the legacy-alias synthesis (which only applies to
    # final task-arg templating). This engine used to synthesize the
    # aliases into every context, so this resolved and the loop ran where
    # real ansible-playbook failed.
    inventory = File.tempname("ansible-ssh-user-inv", ".ini")
    File.write(inventory, "node ansible_connection=local ansible_user=root\n")

    playbook = File.tempname("ansible-ssh-user-loop-src", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: all
        gather_facts: false
        tasks:
          - name: loop over the alias
            ansible.builtin.debug:
              msg: "item={{ item }}"
            loop:
              - "{{ ansible_ssh_user }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
    status.success?.should be_false
    output.to_s.should contain("'ansible_ssh_user' is undefined")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails a role default referencing the alias when a loop source pulls it in (f500.bashrc shape)" do
    # round900321 f500.bashrc's own defaults/main.yml:
    #   bashrc_users:
    #     - "{{ ansible_ssh_user }}"
    # fed to `with_items: "{{ bashrc_users }}"`. The role default itself
    # stays lazily unrendered, but the LOOP-SOURCE templating recursively
    # renders its elements against the alias-free snapshot - real
    # ansible-playbook fails the task with "'ansible_ssh_user' is
    # undefined" (origin traced to defaults/main.yml's own entry;
    # live-verified), so the loop never runs.
    src_dir = File.tempname("ansible-ssh-user-role-default")
    Dir.mkdir_p(File.join(src_dir, "roles", "rbtest", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "rbtest", "tasks"))
    File.write(File.join(src_dir, "roles", "rbtest", "defaults", "main.yml"), <<-YAML)
      ---
      bashrc_users:
        - "{{ ansible_ssh_user }}"
      YAML
    File.write(File.join(src_dir, "roles", "rbtest", "tasks", "main.yml"), <<-YAML)
      ---
      - name: Determine ssh user
        ansible.builtin.debug:
          msg: "user={{ item }}"
        with_items: "{{ bashrc_users }}"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_user: testuser
        roles:
          - rbtest
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", "localhost,", playbook], output: output, error: output)
    status.success?.should be_false
    output.to_s.should contain("'ansible_ssh_user' is undefined")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "still resolves a role default referencing the alias through task-arg templating (round168 phergie shape)" do
    # round168 geerlingguy.phergie - the fix this scoping must not
    # regress. Its own defaults/main.yml:
    #   phergie_user: "{{ ansible_ssh_user }}"
    #   phergie_install_path: "/home/{{ ansible_ssh_user }}/phergie"
    # referenced by a task's own args (`file: {owner: "{{ phergie_user }}"}`).
    # Structurally near-identical to f500.bashrc's default above, but the
    # downstream usage is task-arg templating, where real Ansible's
    # legacy-alias synthesis IS in scope - both defaults resolve
    # (live-verified against real ansible-playbook; the phergie-shape
    # role's tasks complete ok=2 while the f500-shape role's loop fails).
    src_dir = File.tempname("ansible-ssh-user-phergie")
    Dir.mkdir_p(File.join(src_dir, "roles", "rgtest", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "rgtest", "tasks"))
    File.write(File.join(src_dir, "roles", "rgtest", "defaults", "main.yml"), <<-YAML)
      ---
      phergie_user: "{{ ansible_ssh_user }}"
      phergie_install_path: "/home/{{ ansible_ssh_user }}/phergie"
      YAML
    File.write(File.join(src_dir, "roles", "rgtest", "tasks", "main.yml"), <<-YAML)
      ---
      - name: show user
        ansible.builtin.debug:
          msg: "user={{ phergie_user }}"
      - name: show path
        ansible.builtin.debug:
          msg: "path={{ phergie_install_path }}"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_user: testuser
        roles:
          - rgtest
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", "localhost,", playbook], output: output, error: output)
    status.success?.should be_true
    output.to_s.should contain("user=testuser")
    output.to_s.should contain("path=/home/testuser/phergie")
    output.to_s.should_not contain("is undefined")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end
end
