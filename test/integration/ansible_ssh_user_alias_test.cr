require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "ansible_ssh_user/ansible_ssh_host/ansible_ssh_port legacy aliases" do
  it "resolves the deprecated ansible_ssh_* spelling to whatever the canonical ansible_* var holds" do
    # Real bug found benchmarking round168's geerlingguy.phergie on
    # Ubuntu 22.04: `defaults/main.yml` sets `phergie_user: "{{
    # ansible_ssh_user }}"` (Ansible's variable manager treats
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
    status.success?.must_equal(true)
    output.to_s.must_include("ansible_user=root ansible_ssh_user=root")
    output.to_s.wont_include("is undefined")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "still resolves the alias in a looped task's own argument templating" do
    # The other half of the round900321 scoping fix: the alias-free
    # snapshot applies to loop-SOURCE resolution only - a task ARG that
    # references ansible_ssh_user (even on a looped task, where args are
    # templated per item against the full context) must keep resolving,
    # exactly as ansible-playbook does (live-verified).
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
    status.success?.must_equal(true)
    output.to_s.must_include("user=root item=1")
    output.to_s.must_include("user=root item=2")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "banners a task name referencing the alias as an undefined-error marker while the args resolve" do
    # hannseman.raspbian: `name: setup ssh user {{ ansible_ssh_user }}`
    # with only ansible_user set banners as `<< error 1 - ... >>` on
    # ansible-playbook (live-verified), while the task's args still
    # resolve the alias.
    inventory = File.tempname("ansible-ssh-user-inv", ".ini")
    File.write(inventory, "node ansible_connection=local ansible_user=root\n")

    playbook = File.tempname("ansible-ssh-user-name", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: all
        gather_facts: false
        tasks:
          - name: setup ssh user {{ ansible_ssh_user }}
            ansible.builtin.debug:
              msg: "user={{ ansible_ssh_user }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
    status.success?.must_equal(true)
    output.to_s.must_include("TASK [setup ssh user << error 1 - 'ansible_ssh_user' is undefined >>]")
    output.to_s.must_include("user=root")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails a loop: source list referencing the alias (Ansible's scoping)" do
    # round900321 f500.bashrc, live-verified against ansible-playbook:
    # `loop: ["{{ ansible_ssh_user }}"]` with only ansible_user set is a
    # HARD task failure ("'ansible_ssh_user' is undefined") -
    # Ansible's loop-source resolution renders against a vars snapshot
    # that never saw the legacy-alias synthesis (which only applies to
    # final task-arg templating). This engine used to synthesize the
    # aliases into every context, so this resolved and the loop ran where
    # ansible-playbook failed.
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
    status.success?.must_equal(false)
    output.to_s.must_include("'ansible_ssh_user' is undefined")
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
    # renders its elements against the alias-free snapshot -
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
    status = Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: output, error: output)
    status.success?.must_equal(false)
    output.to_s.must_include("'ansible_ssh_user' is undefined")
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
    # downstream usage is task-arg templating, where Ansible's
    # legacy-alias synthesis IS in scope - both defaults resolve
    # (live-verified against ansible-playbook; the phergie-shape
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
    status = Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: output, error: output)
    status.success?.must_equal(true)
    output.to_s.must_include("user=testuser")
    output.to_s.must_include("path=/home/testuser/phergie")
    output.to_s.wont_include("is undefined")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "fails a become_user keyword routed through a role default referencing the alias (issue #420 shape)" do
    # ansible-role.nodejs round29883507: its own defaults/main.yml
    #   role_nodejs_nvm_user: "{{ ansible_ssh_user }}"
    # fed `become_user: "{{ role_nodejs_nvm_user }}"`. Ansible-core
    # 2.19.11 templates the become keywords WITHOUT the legacy-alias
    # synthesis (live-verified: the task fails "'ansible_ssh_user' is
    # undefined" with the innermost Origin at the defaults line, play
    # exit 2) even with ansible_user set, while the same reference in
    # the task's args resolves. This engine used to render the keyword
    # from the full task-arg context, so the alias resolved and the
    # task RAN (exit 0) where ansible aborted the play.
    src_dir = File.tempname("ansible-ssh-user-become")
    Dir.mkdir_p(File.join(src_dir, "roles", "rntest", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "rntest", "tasks"))
    File.write(File.join(src_dir, "roles", "rntest", "defaults", "main.yml"), <<-YAML)
      ---
      nvm_user: "{{ ansible_ssh_user }}"
      YAML
    File.write(File.join(src_dir, "roles", "rntest", "tasks", "main.yml"), <<-YAML)
      ---
      - name: Install NVM
        ansible.builtin.command: /bin/true
        become: false
        become_user: "{{ nvm_user }}"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_user: testuser
        roles:
          - rntest
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook], output: output, error: output)
    status.success?.must_equal(false)
    output.to_s.must_include("[ERROR]: Task failed: Error processing keyword 'become_user': 'ansible_ssh_user' is undefined")
    # The routed shape keeps the THREE-link chain (bare middle link, the
    # innermost bare "'x' is undefined" Origin'd at the defaults line) -
    # unlike the direct reference's collapsed two-link chain below.
    output.to_s.must_include("Error processing keyword 'become_user'.\nOrigin")
    output.to_s.must_include("'ansible_ssh_user' is undefined\nOrigin: #{File.join(src_dir, "roles", "rntest", "defaults", "main.yml")}")
    output.to_s.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Error processing keyword 'become_user': 'ansible_ssh_user' is undefined\"}")
    output.to_s.must_include("failed=1")
    output.to_s.wont_include("changed: [localhost]")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir && Dir.exists?(src_dir)
  end

  it "fails a direct become_user keyword reference to the alias with ansible's collapsed chain" do
    # The same matrix, DIRECT (no role-default indirection), live-
    # verified vs ansible-core 2.19.11: `become_user:` fails even under
    # `become: false` (ansible validates the keyword before the module
    # runs), and because the failing reference IS the keyword value
    # there is no separate definition site to point at, so the [ERROR]
    # chain collapses to two links with the bare message folded into
    # the middle segment, Origin'd at the keyword VALUE (block-form
    # become_user: counted at the quoted value's own line/column).
    inventory = File.tempname("ansible-ssh-user-inv", ".ini")
    File.write(inventory, "node ansible_connection=local ansible_user=root\n")

    playbook = File.tempname("ansible-ssh-user-become-direct", ".yml")
    File.write(playbook,
      "- name: p1\n  hosts: all\n  gather_facts: false\n  tasks:\n" \
      "    - name: become_user direct\n      ansible.builtin.command: /bin/true\n      become: false\n" \
      "      become_user:\n        \"{{ ansible_ssh_user }}\"\n")

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
    status.success?.must_equal(false)
    output.to_s.must_include("Error processing keyword 'become_user': 'ansible_ssh_user' is undefined\nOrigin: #{playbook}:9:9")
    # The direct shape never shows the three-link bare middle, and the
    # task never runs.
    output.to_s.wont_include("Error processing keyword 'become_user'.\nOrigin")
    output.to_s.wont_include("changed: [node]")
    output.to_s.must_include("failed=1")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "fails a direct become keyword reference to the alias as undefined, not a bool conversion" do
    # `become: "{{ ansible_ssh_user }}"` on ansible-core 2.19.11: the
    # keyword template never sees the alias, so it fails "'x' is
    # undefined" - the old full-context render resolved 'labros' and
    # reported a bogus could-not-be-converted-to-'bool' wording instead
    # (live-captured side by side next to issue #420).
    inventory = File.tempname("ansible-ssh-user-inv", ".ini")
    File.write(inventory, "node ansible_connection=local ansible_user=root\n")

    playbook = File.tempname("ansible-ssh-user-become-bool", ".yml")
    File.write(playbook,
      "- name: p1\n  hosts: all\n  gather_facts: false\n  tasks:\n" \
      "    - name: become direct\n      ansible.builtin.command: /bin/true\n" \
      "      become: \"{{ ansible_ssh_user }}\"\n")

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
    status.success?.must_equal(false)
    output.to_s.must_include("Error processing keyword 'become': 'ansible_ssh_user' is undefined\nOrigin: #{playbook}:7:15")
    output.to_s.wont_include("could not be converted to 'bool'")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "still resolves an explicitly-set ansible_ssh_user in become_user (a real var, not the alias)" do
    # The alias-free snapshot only WITHDRAWS the synthesized spelling;
    # an ansible_ssh_user actually set as an inventory/play var is a
    # real variable ansible's keyword templating sees (live-verified:
    # the task runs ok with ansible_become false). Guards the rebuild's
    # explicit-var survival, same guarantee as the loop-source snapshot.
    inventory = File.tempname("ansible-ssh-user-inv", ".ini")
    File.write(inventory, "node ansible_connection=local ansible_ssh_user=root\n")

    playbook = File.tempname("ansible-ssh-user-become-explicit", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: all
        gather_facts: false
        tasks:
          - name: become_user explicit
            ansible.builtin.command: /bin/true
            become: false
            become_user: "{{ ansible_ssh_user }}"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
    status.success?.must_equal(true, output.to_s)
    output.to_s.wont_include("'ansible_ssh_user' is undefined")
    output.to_s.must_include("changed: [node]")
  ensure
    File.delete(inventory) if inventory && File.exists?(inventory)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
