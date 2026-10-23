require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook, since this bug is
# in the executor's controller-side include_vars: dispatch, not
# something a unit spec against a single method can exercise cleanly
# (it needs the real loop/vars/when interplay end to end).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

describe "include_vars: with a literal loop: (not with_first_found:)" do
  it "evaluates when: per item, with `item` bound, instead of skipping the whole task" do
    # Real bug found benchmarking linux-system-roles.storage (round
    # 159). Its own tasks/set_vars.yml has:
    #   include_vars: "{{ __vars_file }}"
    #   loop: ["{{ os_family }}.yml", "{{ distribution }}_{{ major }}.yml", ...]
    #   vars:
    #     __vars_file: "{{ role_path }}/vars/{{ item }}"
    #   when: __vars_file is file
    # include_vars: only ever supported with_first_found: as a loop
    # form - a plain loop: was dispatched straight to
    # execute_include_vars before the executor's generic loop-handling
    # ever ran, so the task executed once with `item` never bound:
    # `__vars_file` rendered with a literal "undefined" item, the
    # `is file` test failed for every candidate, and the whole task
    # silently skipped instead of loading the one candidate that
    # actually exists on disk.
    src_dir = File.tempname("include-vars-loop-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "vars"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "vars", "present.yml"), "myvar: [foo, bar]\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Set platform/version specific variables
        include_vars: "{{ __vars_file }}"
        loop:
          - "absent.yml"
          - "present.yml"
        vars:
          __vars_file: "{{ role_path }}/vars/{{ item }}"
        when: __vars_file is file
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include("ok: [localhost] => (item=present.yml)")
    output.to_s.must_include("skipping: [localhost] => (item=absent.yml)")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end

describe "include_vars: with with_fileglob: (not with_first_found:/loop:)" do
  it "globs the pattern and includes every match, instead of running once with item unbound" do
    # Real bug found benchmarking round168's geerlingguy.php_versions on
    # Ubuntu 22.04: `include_vars: "{{ item }}" with_fileglob: ["{{
    # role_path }}/vars/{{ ansible_facts.os_family }}.yml", ...]` -
    # parse_include_vars_task only ever recognized with_first_found:/
    # loop: as this module's loop forms, unlike the generic task parser
    # (which sets task.loop_fileglob for every other module). `item`
    # stayed completely unbound, rendering the literal text "undefined"
    # and failing with "include_vars: file not found: undefined"
    # instead of globbing the vars/ directory the way Ansible does.
    src_dir = File.tempname("include-vars-fileglob-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "vars"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "vars", "match.yml"), "myvar: hello\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Include OS-specific variables.
        include_vars: "{{ item }}"
        with_fileglob:
          - "{{ role_path }}/vars/*.yml"
      - name: show it
        debug:
          var: myvar
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include("ok: [localhost] => (item=")
    output.to_s.must_include("match.yml)")
    output.to_s.must_include("myvar")
    output.to_s.must_include("hello")
    output.to_s.wont_include("file not found: undefined")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "displays a skipped loop item's dict value as Python repr (matching real), not Crystal's JSON::Any inspect text" do
    # Real bug found via a live 100-role confirm round: ipr-cnrs.
    # nftables's own looped include_vars: task, gated by a false
    # when:, printed "skipping: ... => (item={\"changed\" =>
    # JSON::Any(false), ...})" - Crystal's raw JSON::Any#to_s/inspect
    # text - instead of the clean JSON-ish display every other looped
    # task in this codebase already uses (item_display).
    src_dir = File.tempname("include-vars-skip-item-display")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: skip this
        include_vars: "{{ item.name }}"
        loop:
          - name: a.yml
            groupname: ungrouped
        when: false
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    # Real renders the loop item with Python repr (`'key'` single-quoted,
    # `, ` separators) - verified against ansible-core 2.19.11 - so the
    # item label is `{'name': 'a.yml', 'groupname': 'ungrouped'}`, not the
    # compact JSON krikri used to emit.
    output.to_s.must_include(%({'name': 'a.yml', 'groupname': 'ungrouped'}))
    output.to_s.wont_include("JSON::Any(")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end

describe "include_vars: with a literal with_items: array (not found/glob/loop:)" do
  it "loops the include once per item and loads every existing file's vars" do
    # Real bug found benchmarking round 29878882's dotstrap.fzf (issue
    # #264): its own "setup" task is `include_vars: "{{ item }}"` paired
    # with a literal `with_items: ["{{ ansible_user_shell | basename }}.
    # yml", "{{ ansible_pkg_mgr }}.yml"]`. parse_include_vars_task's loop
    # chain had no branch for a with_items: array at all (unlike the
    # generic task parser, which sets the same literal-loop fields for
    # every OTHER module), so the include ran exactly once with `item`
    # unbound and fataled "Error while resolving value for '_raw_params':
    # 'item' is undefined" before any file was even looked up, while real
    # runs the include once per item.
    src_dir = File.tempname("include-vars-with-items-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "vars"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "defaults", "main.yml"), "user_shell: /bin/bash\npkg_mgr: dnf\n")
    File.write(File.join(src_dir, "roles", "myrole", "vars", "bash.yml"), "shell_var: from-bash\n")
    File.write(File.join(src_dir, "roles", "myrole", "vars", "dnf.yml"), "pkg_var: from-dnf\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: setup
        include_vars: "{{ item }}"
        with_items:
          - "{{ user_shell | basename }}.yml"
          - "{{ pkg_mgr }}.yml"
      - name: show it
        debug:
          msg: "{{ shell_var }}/{{ pkg_var }}"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include("ok: [localhost] => (item=bash.yml)")
    output.to_s.must_include("ok: [localhost] => (item=dnf.yml)")
    output.to_s.must_include("from-bash/from-dnf")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "fails per item on a missing file while earlier items still load" do
    # The same dotstrap.fzf shape (issue #264) with one file the role
    # does not ship: real binds and loads item 1 (ok), then fails item
    # 2 per-item - "failed: [testhost] (item=dnf.yml) => {...Could not
    # find or access 'dnf.yml'...}" - instead of krikri's pre-fix shape,
    # fataled on the unbound `item` before ANY item ran ("[ERROR]: Task
    # failed: Finalization of task args for 'ansible.builtin.include_vars'
    # failed: ... 'item' is undefined") - which aborted the whole run's
    # host rather than just failing the task.
    src_dir = File.tempname("include-vars-with-items-missing")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "vars"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "defaults"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "defaults", "main.yml"), "user_shell: /bin/bash\npkg_mgr: dnf\n")
    File.write(File.join(src_dir, "roles", "myrole", "vars", "bash.yml"), "shell_var: from-bash\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: setup
        include_vars: "{{ item }}"
        with_items:
          - "{{ user_shell | basename }}.yml"
          - "{{ pkg_mgr }}.yml"
      - name: sentinel
        debug:
          msg: "SENTINEL-SHOULD-NOT-RUN"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.exit_code.must_equal(2)
    output.to_s.must_include("ok: [localhost] => (item=bash.yml)")
    # Ansible's loop-item action-failure shape (live-verified vs 2.19.11):
    # the [ERROR] block first, over the task's own source position; then
    # the failed dump (item before the =>) whose msg is the action-level
    # collapse and whose message key holds the search-list detail.
    output.to_s.must_include("[ERROR]: Task failed: Action failed: Unknown error.")
    output.to_s.must_include("failed: [localhost] (item=dnf.yml) => {")
    output.to_s.must_include("Could not find or access")
    output.to_s.wont_include("'item' is undefined")
    output.to_s.wont_include("SENTINEL-SHOULD-NOT-RUN")
    output.to_s.must_include("failed=1")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
