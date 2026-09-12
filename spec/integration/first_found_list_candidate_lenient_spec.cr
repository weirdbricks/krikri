require "../spec_helper"

# with_first_found: LIST-form candidates are templated leniently by real
# Ansible - the candidate strings go to the first_found lookup plugin, which
# renders undefined references to nothing, so a candidate that references a
# missing dict key (e.g. `{{ ansible_lsb.id }}` on a host without lsb_release,
# or an explicitly-defined empty dict) simply never matches a file. When NO
# candidate matches, the task fails with the clean first_found exhaustion
# error - NOT an "object of type 'dict' has no attribute 'id'" template
# exception. Found via pluggero.upgrade (round 601548), whose
# 01_install.yml's last candidate is `noauto_install_{{ ansible_lsb.id
# }}.yml` and which ships no RedHat-family file at all: real ansible-core
# 2.19.4 recaps failed=1 with "No file was found when using first_found.",
# krikri recap failed with the raw attribute exception instead.
#
# The SCALAR string form (`with_first_found: "{{ undefined_var }}"`) stays
# strict - real Ansible templates the keyword's own value strictly there
# (round174 matrix scenario 5b, verified live against the same 2.19.4:
# "Task failed: 'undefined_var' is undefined") - see
# loop_source_strict_undefined_spec.cr's with_first_found example.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String)
  playbook = File.tempname("first-found-lenient", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "with_first_found list-form candidates are lenient about undefined references" do
  it "fails with the clean first_found exhaustion error, not a dict-attribute exception" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          some_dict: {}
        tasks:
          - name: First found with missing attr on empty dict
            ansible.builtin.debug:
              msg: "found {{ item }}"
            with_first_found:
              - "/tmp/does-not-exist-a-{{ some_dict.missing_key }}.yml"
              - "/tmp/does-not-exist-b.yml"
      YAML

    status.exit_code.should eq(2)
    output.should contain("No file was found when using first_found")
    output.should_not contain("has no attribute")
    output.should contain("failed=1")
  end

  it "treats a bare undefined list candidate the same lenient way" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Bare undefined candidate
            ansible.builtin.debug:
              msg: "found {{ item }}"
            with_first_found:
              - "{{ undefined_var }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("No file was found when using first_found")
    output.should_not contain("'undefined_var' is undefined")
  end

  it "keeps the scalar string form strict (scenario 5b)" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: looped
            ansible.builtin.debug:
              msg: "static text"
            with_first_found: "{{ undefined_var }}"
      YAML

    status.exit_code.should eq(2)
    output.should contain("'undefined_var' is undefined")
    output.should_not contain("No file was found")
  end
end
