require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug is in the
# strict include_vars path scan + strict lookup-arg rendering interplay,
# which needs a real include_vars: task with a task-level vars: dict to
# exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "the `omit` magic bareword inside a first_found lookup's args" do
  it "does not fail an include_vars: task whose candidates default a missing fact to omit" do
    # Real bug found benchmarking Stouts.openvpn (Atlantic round 300077):
    # its "Include OS-specific variables." task is
    #   include_vars: file: "{{ lookup('first_found', params) }}"
    #   vars: params: { files: ["{{ ansible_distribution }}.{{
    #     ansible_lsb.codename | default(omit) }}.yml", ...],
    #     paths: ['vars/os'] }
    # On hosts without ansible_lsb, real ansible-playbook (core 2.19.4,
    # verified live) renders `default(omit)` to the omit marker - which
    # stringifies to empty text mid-string ("Debian..yml", verified) -
    # the candidate misses, and the run falls through to the next entry
    # and succeeds (ok=37). krikri failed the task with "'omit' is
    # undefined": the strict include_vars path scan recursed into the
    # RAW task-vars params and flagged `default(omit)`'s own ARGUMENT
    # `omit` as an undefined bare reference, and the strict span render
    # independently flagged the chain's root (`'ansible_lsb' is
    # undefined`) without honoring that default(...) consumes undefined.
    src_dir = File.tempname("omit-in-first-found-args")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "vars", "os"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "vars", "os", "Common.yml"), "commonvar: from_common_yml\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Include OS-specific variables.
        include_vars:
          file: "{{ lookup('first_found', params) }}"
        vars:
          params:
            files:
              - "{{ ansible_distribution }}.{{
                    ansible_lsb.codename | default(omit) }}.yml"
              - "{{ ansible_distribution }}.yml"
              - "Common.yml"
            paths:
              - 'vars/os'
      - name: show
        debug:
          var: commonvar
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

    status.success?.should be_true
    output.to_s.should contain("commonvar: from_common_yml")
    output.to_s.should_not contain("is undefined")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
