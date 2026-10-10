require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug is in which
# role subdirs the executor's with_first_found: KEYWORD form (not the
# lookup('first_found', ...) function form) searches by default, which
# only shows up with a real role dispatch.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "with_first_found: default search roots vs the task's action" do
  it "never matches vars/ for an include_tasks: with_first_found:, even when vars/ has the candidate" do
    # Real divergence benchmarking ccdc.ntp_configuration: its "Set up
    # NTP time synchronisation" include_tasks: + with_first_found: has
    # bare OS candidates and, on Debian, tasks/Debian.yml does not exist
    # but vars/Debian.yml (a vars MAPPING) does. ansible-playbook
    # (core 2.19.x) skips straight past it and resolves to
    # tasks/Linux.yml; krikri searched vars/ before tasks/ and matched
    # vars/Debian.yml, failing with "Included tasks file must be a YAML
    # list". A vars file can never be a valid include target, so vars/
    # (and files//templates/) must not be searched at all for an
    # include_tasks: action.
    src_dir = File.tempname("first-found-include-tasks-not-vars")
    role = File.join(src_dir, "roles", "myrole")
    Dir.mkdir_p(File.join(role, "tasks"))
    Dir.mkdir_p(File.join(role, "vars"))
    File.write(File.join(role, "vars", "Debian.yml"), <<-YAML)
      ntp_marker: from-vars-debian-yml
      YAML
    File.write(File.join(role, "tasks", "Linux.yml"), <<-YAML)
      - name: linux specific tasks
        ansible.builtin.debug:
          msg: TASKS_LINUX_YML
      YAML
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - name: Set up NTP time synchronisation
        include_tasks: "{{ taskfile }}"
        with_first_found:
          - "{{ ansible_distribution }}-{{ ansible_distribution_major_version }}.yml"
          - "{{ ansible_distribution }}.yml"
          - "{{ ansible_os_family }}.yml"
          - "{{ ansible_system }}.yml"
        loop_control:
          loop_var: taskfile
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_distribution: Debian
          ansible_distribution_major_version: "13"
          ansible_os_family: Debian
          ansible_system: Linux
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include("TASKS_LINUX_YML")
    output.to_s.wont_include("must be a YAML list")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "still finds an include_vars: with_first_found: candidate living under the role's tasks/ dir" do
    # Real divergence benchmarking so5.ssh_hostbased_auth and so5.pbspro:
    # their "include OS specific vars." include_vars: + with_first_found:
    # dict form (files: [...], no paths:) names a setup-<OS>.yml file
    # that only exists under tasks/ (never vars/ or files/). include_
    # file_dir is only set for include_tasks: statements, so a task
    # declared directly in a role's top-level tasks/main.yml previously
    # had no tasks/ root at all - the lookup exhausted and failed with
    # "No file was found when using first_found." where Ansible
    # resolved to tasks/setup-Debian.yml and the role ran to completion.
    src_dir = File.tempname("first-found-include-vars-under-tasks")
    role = File.join(src_dir, "roles", "myrole")
    Dir.mkdir_p(File.join(role, "tasks"))
    Dir.mkdir_p(File.join(role, "vars"))
    File.write(File.join(role, "vars", "main.yml"), <<-YAML)
      unrelated: var
      YAML
    File.write(File.join(role, "tasks", "setup-Debian.yml"), <<-YAML)
      os_marker: from-tasks-setup-debian
      YAML
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - name: include OS specific vars.
        include_vars: "{{ item }}"
        with_first_found:
          - files:
              - "setup-{{ ansible_distribution }}-{{ ansible_distribution_major_version }}.yml"
              - "setup-{{ ansible_distribution }}.yml"
              - "setup-{{ ansible_os_family }}.yml"
            skip: false
      - name: show loaded var
        ansible.builtin.debug:
          msg: "os_marker={{ os_marker }}"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_distribution: Debian
          ansible_distribution_major_version: "13"
          ansible_os_family: Debian
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include("os_marker=from-tasks-setup-debian")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "prefers vars/ over tasks/ for an include_vars: with_first_found: with a custom paths: sub-key (dochang.lsbrelease shape)" do
    # Real divergence benchmarking dochang.lsbrelease (round 5410432):
    # its "include os specific variables" include_vars: + with_first_found:
    # dict form carries paths: [install] and both tasks/install/default.yml
    # (a task LIST) and vars/install/default.yml (the lsbrelease_package
    # vars MAPPING) exist. ansible-playbook (core 2.19.11, probed live
    # 2026-10-10) resolves the include_vars: to vars/install/default.yml;
    # krikri anchored the custom paths: at the including file's dir
    # unconditionally and picked tasks/install/default.yml - merged zero
    # variables - so the later package task failed with
    # "'lsbrelease_package' is undefined". Verified live with the same
    # probe shape: with vars/ present the vars/ copy wins even though the
    # tasks/ copy exists too.
    src_dir = File.tempname("first-found-include-vars-custom-paths-vars-first")
    role = File.join(src_dir, "roles", "myrole")
    Dir.mkdir_p(File.join(role, "tasks", "install"))
    Dir.mkdir_p(File.join(role, "vars", "install"))
    File.write(File.join(role, "vars", "install", "default.yml"), <<-YAML)
      lsbrelease_package: from-vars-install
      YAML
    File.write(File.join(role, "tasks", "install", "default.yml"), <<-YAML)
      - name: not a vars file
        ansible.builtin.debug:
          msg: TASKS_INSTALL_DEFAULT_YML
      YAML
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - name: include os specific variables
        include_vars: '{{ item }}'
        with_first_found:
          - files:
              - '{{ ansible_distribution }}.yml'
              - '{{ ansible_os_family }}.yml'
              - default.yml
            paths:
              - install
      - name: show loaded var
        ansible.builtin.debug:
          msg: "lsbrelease_package={{ lsbrelease_package }}"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_distribution: Debian
          ansible_os_family: Debian
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include("lsbrelease_package=from-vars-install")
    output.to_s.wont_include("TASKS_INSTALL_DEFAULT_YML")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "prefers the role's files/ copy over tasks/ and vars/ for a generic task's with_first_found: with a custom paths: sub-key" do
    # Probed live against ansible-core 2.19.11 (2026-10-10): for a generic
    # task (debug:, action contains neither "template" nor "var") the
    # first_found lookup resolves with subdir "files", so the role's files/
    # copy wins even with the same basename present under tasks/ and vars/.
    # krikri previously anchored custom paths: at the including file's dir
    # (tasks/) first and never searched files/ at all.
    src_dir = File.tempname("first-found-generic-custom-paths-files-first")
    role = File.join(src_dir, "roles", "myrole")
    Dir.mkdir_p(File.join(role, "tasks", "sub"))
    Dir.mkdir_p(File.join(role, "files", "sub"))
    Dir.mkdir_p(File.join(role, "vars", "sub"))
    File.write(File.join(role, "files", "sub", "candidate.txt"), "from-files")
    File.write(File.join(role, "tasks", "sub", "candidate.txt"), "from-tasks")
    File.write(File.join(role, "vars", "sub", "candidate.txt"), "ivv: from-vars")
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - name: generic first found
        ansible.builtin.debug:
          msg: "GENERIC {{ item }}"
        with_first_found:
          - files:
              - candidate.txt
            paths:
              - sub
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
    output.to_s.must_include("GENERIC #{File.join(role, "files", "sub", "candidate.txt")}")
    output.to_s.wont_include("GENERIC #{File.join(role, "tasks", "sub", "candidate.txt")}")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "prefers the role's tasks/ copy over vars/ for a generic task's with_first_found: once files/ has no candidate" do
    # Same probe shape as above with the files/ candidate removed: real
    # ansible-core 2.19.11 then resolves the tasks/ copy over the vars/
    # copy (both present here).
    src_dir = File.tempname("first-found-generic-custom-paths-tasks-over-vars")
    role = File.join(src_dir, "roles", "myrole")
    Dir.mkdir_p(File.join(role, "tasks", "sub"))
    Dir.mkdir_p(File.join(role, "vars", "sub"))
    File.write(File.join(role, "tasks", "sub", "candidate.txt"), "from-tasks")
    File.write(File.join(role, "vars", "sub", "candidate.txt"), "ivv: from-vars")
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - name: generic first found
        ansible.builtin.debug:
          msg: "GENERIC {{ item }}"
        with_first_found:
          - files:
              - candidate.txt
            paths:
              - sub
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
    output.to_s.must_include("GENERIC #{File.join(role, "tasks", "sub", "candidate.txt")}")
    output.to_s.wont_include("GENERIC #{File.join(role, "vars", "sub", "candidate.txt")}")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "prefers vars/ over tasks/ for an include_vars: with_first_found: when both hold the same basename" do
    # Real divergence benchmarking mircomasa.filebeat (round 812001): its
    # "Load a variable file based on the OS type" include_vars: +
    # with_first_found: candidate '{{ ansible_system }}.yml' exists in the
    # role BOTH as tasks/Linux.yml (a task LIST) and vars/Linux.yml (a vars
    # MAPPING defining a `default:` dict). ansible-playbook (core
    # 2.19.x, verified live) resolves the include_vars: to the vars/ copy;
    # krikri searched tasks/ before vars/ and loaded the tasks/ copy,
    # merging zero variables, so the role's own
    # defaults/main.yml fb_home: '{{ default["fb_home"] }}' failed with
    # "'default[\"fb_home\"]' is undefined" at the first task that rendered
    # it - even though the include_vars: task itself had reported ok.
    src_dir = File.tempname("first-found-include-vars-vars-before-tasks")
    role = File.join(src_dir, "roles", "myrole")
    Dir.mkdir_p(File.join(role, "tasks"))
    Dir.mkdir_p(File.join(role, "vars"))
    Dir.mkdir_p(File.join(role, "defaults"))
    File.write(File.join(role, "vars", "Linux.yml"), <<-YAML)
      default:
        fb_home: /usr/share/filebeat
      YAML
    File.write(File.join(role, "tasks", "Linux.yml"), <<-YAML)
      - name: linux specific tasks
        ansible.builtin.debug:
          msg: TASKS_LINUX_YML
      YAML
    File.write(File.join(role, "defaults", "main.yml"), <<-YAML)
      fb_home: '{{ default["fb_home"] }}'
      YAML
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - name: Load a variable file based on the OS type
        include_vars: '{{ platform_vars }}'
        with_first_found:
          - '{{ ansible_system }}.yml'
          - default.yml
        loop_control:
          loop_var: platform_vars
      - name: render the role default
        ansible.builtin.debug:
          msg: "fb_home={{ fb_home }}"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_system: Linux
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include("fb_home=/usr/share/filebeat")
    output.to_s.wont_include("is undefined")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
