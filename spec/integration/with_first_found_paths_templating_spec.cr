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
end
