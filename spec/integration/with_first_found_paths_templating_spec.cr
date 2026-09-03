require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug is in the
# executor's controller-side with_first_found: custom paths: resolution,
# which needs a real role_path/vars/loop interplay to exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "with_first_found: a custom paths: entry containing {{ role_path }}" do
  it "templates each custom path before joining it against the role root, instead of doubling the literal template text into the path" do
    # Real bug found benchmarking andrewrothstein.buildah (a 3-way
    # krikri-playbook/ansible-playbook/Mitogen benchmark round). Its
    # dependency roles (andrewrothstein.kubic, andrewrothstein.gpg) use
    # the common idiom:
    #   with_first_found:
    #     - files: ["{{ ansible_distribution }}.yml", "{{ ansible_os_family }}.yml"]
    #       paths: ["{{ role_path }}/vars"]
    # resolve_first_found_path's custom-paths branch joined
    # task.role_path onto the RAW, unrendered "{{ role_path }}/vars"
    # string (it doesn't start with "/"), producing a garbage path with
    # literal "{{"/"}}" characters that could never exist on disk.
    # Every candidate then missed and `skip: true` turned that into a
    # silent skip instead of a visible failure - the role's own
    # kubic_pkg_mgr var (set inside the file that was never loaded)
    # stayed undefined, silently skipping the rest of the role's tasks
    # too, while real ansible-playbook actually loads the file and
    # proceeds.
    src_dir = File.tempname("first-found-custom-paths-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "vars"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "vars", "Debian.yml"), "myvar: from_debian_yml\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Resolve platform specific vars
        include_vars: "{{ item }}"
        with_first_found:
          - files:
              - "{{ ansible_distribution }}-{{ ansible_distribution_release }}.yml"
              - "{{ ansible_distribution }}.yml"
              - "{{ ansible_os_family }}.yml"
            skip: true
            paths:
              - "{{ role_path }}/vars"
      - name: show myvar
        debug:
          var: myvar
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_distribution: Ubuntu
          ansible_distribution_release: noble
          ansible_os_family: Debian
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should_not contain("skipping: [localhost]")
    output.to_s.should contain("myvar: from_debian_yml")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "resolves a RELATIVE custom paths: entry against the including file's own directory, not the role root" do
    # Real bug found via a live 100-role confirm round: three
    # independent real roles (sbaerlocher.powercfg/.onedrive/
    # .domain-membership) all hit this identically with their own
    # "include distribution tasks" idiom -
    # `with_first_found: {files: [...], paths: ["distribution"]}` on an
    # include_tasks: task living directly in the role's own
    # tasks/main.yml. Verified live against ansible-core 2.19.12
    # (-vv output: "included: .../tasks/distribution/Linux.yml") - a
    # relative paths: entry resolves against the directory of the FILE
    # the with_first_found: task is itself written in
    # (roles/<role>/tasks/), not the role root
    # (roles/<role>/distribution/, which is what the earlier
    # andrewrothstein.buildah fix above assumed for EVERY custom
    # paths: entry, unverified for this shape). This engine previously
    # only ever tried the role-root anchor, so the real
    # roles/<role>/tasks/distribution/Linux.yml file was never found -
    # every candidate missed and the task silently skipped instead of
    # including the real distribution-specific tasks.
    src_dir = File.tempname("first-found-relative-paths-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks", "distribution"))
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "distribution", "Linux.yml"), <<-YAML)
      - name: linux specific
        ansible.builtin.debug:
          msg: MATCHED_LINUX_YML
      YAML
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: include distribution tasks
        include_tasks: "{{ loop_distribution }}"
        with_first_found:
          - files:
              - "{{ ansible_system }}.yml"
              - "defaults.yml"
            paths:
              - "distribution"
        loop_control:
          loop_var: loop_distribution
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should_not contain("skipping: [localhost]")
    output.to_s.should contain("MATCHED_LINUX_YML")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
