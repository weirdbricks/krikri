require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug is in how the
# parser collects the with_first_found: KEYWORD form's candidate list across
# MULTIPLE list terms, which only shows up with a real role dispatch.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "with_first_found: multiple list terms (Frzk.nftables shape)" do
  it "reads files: from the second dict term after a paths:-only first term" do
    # Real divergence benchmarking Frzk.nftables: its "include OS specific
    # variables" include_vars: + with_first_found: lists a paths:-only
    # dict term FIRST and the files:/skip: dict term SECOND. ansible's
    # first_found walks every term and finds vars/Debian.yml; krikri used
    # to read only the first entry, got no files: at all, and failed with
    # "The lookup plugin 'first_found' failed: No file was found".
    src_dir = File.tempname("first-found-multi-term")
    role = File.join(src_dir, "roles", "myrole")
    Dir.mkdir_p(File.join(role, "tasks"))
    Dir.mkdir_p(File.join(role, "vars"))
    File.write(File.join(role, "vars", "Debian.yml"), <<-YAML)
      nftables_marker: from-vars-debian-yml
      YAML
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - name: include OS specific vars
        include_vars: "{{ item }}"
        with_first_found:
          - paths: ["vars"]
          - files: ["{{ ansible_distribution }}-{{ ansible_distribution_major_version }}.yml", "{{ ansible_distribution }}.yml", "{{ ansible_os_family }}.yml"]
            skip: yes
      - name: show loaded var
        ansible.builtin.debug:
          msg: "nftables_marker={{ nftables_marker }}"
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
    output.to_s.must_include("nftables_marker=from-vars-debian-yml")
    output.to_s.wont_include("No file was found")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "still finds nothing when no term's files: exist and skip: is on a later term" do
    # Same two-term shape but no candidate exists anywhere: skip: on the
    # second term must still make the miss non-fatal (the task skips, the
    # play continues) - a skip: on ANY dict term covers the whole lookup.
    src_dir = File.tempname("first-found-multi-term-skip")
    role = File.join(src_dir, "roles", "myrole")
    Dir.mkdir_p(File.join(role, "tasks"))
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - name: include OS specific vars
        include_vars: "{{ item }}"
        with_first_found:
          - paths: ["vars"]
          - files: ["{{ ansible_distribution }}-{{ ansible_distribution_major_version }}.yml", "{{ ansible_distribution }}.yml", "{{ ansible_os_family }}.yml"]
            skip: yes
      - name: mark reached
        ansible.builtin.debug:
          msg: REACHED_AFTER_SKIP
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
    output.to_s.must_include("REACHED_AFTER_SKIP")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
