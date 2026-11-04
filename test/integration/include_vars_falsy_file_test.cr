require "../minitest_helper"
require "file_utils"

# include_vars: file argument that resolves to a FALSY native value
# (issue #850, bodsch.mpd).
#
# bodsch.mpd's `include_vars: "{{ lookup('first_found', params) }}"`
# (skip: true, no candidate on Rocky 9) hands include_vars an empty
# LIST. Ansible's AnsibleFileNotFound renders the quoted
# "Could not find or access '<X>'" head ONLY for a truthy file_name -
# a falsy one gets the bare "Could not find file" - while the
# "Searched in:" list is built from the value's str() ("[]"), so the
# paths text is identical either way. krikri used to flatten the
# whole-expression value to its "[]" string first and always quoted it.
#
# Live-verified vs 2.19.11 (free-form _raw_params form):
#   {{ lookup('first_found', params) }} (skip, no match) -> "Could not
#     find file" + Searched in: <base>/vars/[], <base>/[] (x2)
#   {{ false }} -> "Could not find file" + Searched in: .../vars/False
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_falsy_include_vars(playbook : String) : String
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new, chdir: File.dirname(playbook))
  raise "playbook failed with rc=#{status.exit_code}:\n#{output}" unless status.success?
  output.to_s
end

private def falsy_include_vars_message(output : String) : String
  line = output.each_line.find { |text_line| text_line.includes?("FAILED! => {") }
  raise "no FAILED! line in output:\n#{output}" unless line
  JSON.parse(line.sub(/\A.*FAILED! => /, ""))["message"].as_s
end

describe "include_vars file argument resolving to a falsy native value" do
  it "renders the bare Could not find file head for an empty first_found skip result" do
    src_dir = File.tempname("include-vars-falsy")
    Dir.mkdir_p(File.join(src_dir, "vars"))
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: true
        connection: local
        tasks:
          - name: include os specific vars
            ansible.builtin.include_vars: "{{ lookup('first_found', params) }}"
            vars:
              params:
                paths:
                  - "vars"
                files:
                  - "krikri-nomatch-{{ ansible_facts.distribution | lower }}.yml"
                  - "default.yaml"
                skip: true
            ignore_errors: true
      YAML

    output = run_falsy_include_vars(File.join(src_dir, "pb.yml"))
    message = falsy_include_vars_message(output)
    message.must_equal(
      "Could not find file\nSearched in:\n\t#{src_dir}/vars/[]\n\t#{src_dir}/[]\n\t" \
      "#{src_dir}/vars/[]\n\t#{src_dir}/[] on the Ansible Controller.\n" \
      "If you are using a module and expect the file to exist on the remote, see the remote_src option")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "renders the bare Could not find file head for a falsy scalar whole-expression value" do
    src_dir = File.tempname("include-vars-falsy-scalar")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: falsy scalar file
            ansible.builtin.include_vars: "{{ false }}"
            ignore_errors: true
      YAML

    output = run_falsy_include_vars(File.join(src_dir, "pb.yml"))
    message = falsy_include_vars_message(output)
    message.must_equal(
      "Could not find file\nSearched in:\n\t#{src_dir}/vars/False\n\t#{src_dir}/False\n\t" \
      "#{src_dir}/vars/False\n\t#{src_dir}/False on the Ansible Controller.\n" \
      "If you are using a module and expect the file to exist on the remote, see the remote_src option")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
