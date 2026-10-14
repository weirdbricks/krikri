require "file_utils"
require "../minitest_helper"

# The `-> delegate` marker ansible-playbook stamps on a delegated task's
# result lines via CallbackBase.host_label - which reads the task keyword
# itself, so the label appears even on lines whose engine path never
# built a connection to the delegate:
#
#   * practical-ansible.nginx_project's `include_vars: {file: package.json,
#     name: npm}` + `delegate_to: localhost` + `failed_when: false` printed
#     `ok: [testhost]` where real prints `ok: [testhost -> localhost]`
#     (issue #89) - include_vars:' own controller-side display paths never
#     passed a delegate target at all;
#   * inoxio.proxmox_vms's `stat:` + `with_dict: "{{ vms }}"` (vms
#     undefined) + `delegate_to: localhost` printed
#     `fatal: [testhost]: FAILED! => {"changed": false, "msg": "Task
#     failed: 'vms' is undefined"}` where real prints the same dump under
#     `[testhost -> localhost]` - the loop-source failure pipeline lost
#     the already-resolved delegate host before display (issue #89).
#
# A dedicated inventory with a distinct host name (not `localhost`) is
# what makes the marker observable at all: with host == target the
# engines agree by construction.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_delegate_label_playbook(yaml : String, files : Hash(String, String) = {} of String => String)
  dir = Dir.tempdir + "/krikri-delegate-label-#{Random::Secure.hex(4)}"
  FileUtils.mkdir_p(dir)
  inventory = File.join(dir, "inv.ini")
  File.write(inventory, "testhost ansible_connection=local\n")
  playbook = File.join(dir, "play.yml")
  File.write(playbook, yaml)
  files.each { |name, content| File.write(File.join(dir, name), content) }

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "delegated task result lines keep the -> delegate marker" do
  it "marks a delegated include_vars: success line" do
    status, output = run_delegate_label_playbook(<<-YAML,
      - hosts: testhost
        gather_facts: false
        tasks:
          - name: Read npm project meta
            include_vars:
              file: package.json
              name: npm
            delegate_to: localhost
            become: false
            failed_when: false
      YAML
      {"package.json" => %({"name": "demo"})} of String => String)

    status.exit_code.must_equal(0)
    output.must_match(/ok: \[testhost -> localhost\]/)
    output.wont_match(/ok: \[testhost\]\n/)
  end

  it "marks a delegated task's loop-source failure fatal line" do
    status, output = run_delegate_label_playbook(<<-YAML)
      - hosts: testhost
        gather_facts: false
        tasks:
          - name: stat vms
            delegate_to: localhost
            become: false
            stat:
              path: "/etc/x"
            with_dict: "{{ vms }}"
          - name: reached only when the previous failure did not halt the host
            debug:
              msg: "should not print"
      YAML

    status.exit_code.wont_equal(0)
    output.must_match(/fatal: \[testhost -> localhost\]: FAILED! => \{"changed": false, "msg": "Task failed: 'vms' is undefined"\}/)
    output.wont_match(/fatal: \[testhost\]: FAILED/)
    output.wont_match(/should not print/)
  end

  it "marks a delegated task's loop-source failure fatal line under ignore_errors" do
    status, output = run_delegate_label_playbook(<<-YAML)
      - hosts: testhost
        gather_facts: false
        tasks:
          - name: stat vms
            delegate_to: localhost
            become: false
            ignore_errors: true
            stat:
              path: "/etc/x"
            with_dict: "{{ vms }}"
          - name: runs because the failure above is ignored
            debug:
              msg: "continued"
      YAML

    status.exit_code.must_equal(0)
    output.must_match(/fatal: \[testhost -> localhost\]: FAILED! => \{"changed": false, "msg": "Task failed: 'vms' is undefined"\}/)
    output.must_match(/\.\.\.ignoring/)
    output.must_match(/continued/)
  end
end
