require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug lives in the
# script plugin's execution shape (how the invocation reaches the target
# shell), not the task executor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(src_dir : String, playbook : String)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
  {status, output.to_s}
end

describe "script: executable: goes through the target shell like real" do
  it "reports a missing executable: the way the connection shell does (rc 127, dash wording)" do
    # Real's script action hands its command to _low_level_execute_command,
    # which ALWAYS wraps it in `/bin/sh -c '<cmd>'`, so a bogus
    # `executable:` is reported BY that shell (dash: "not found", rc 127).
    # The engine's argv fast path used to direct-exec the first word
    # instead and report its own spawn-failure shape (rc 1, "Local
    # execution failed: Error executing process: ...", issue #926 - found
    # by krikri-playbook-generator's 000147-script-chaos seed).
    src_dir = File.tempname("script-bogus-executable")
    Dir.mkdir_p(src_dir)
    script = File.join(src_dir, "x.sh")
    File.write(script, "#!/bin/sh\necho ran\n")
    File.chmod(script, 0o755)

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
        - name: script with bogus executable
          ansible.builtin.script:
            cmd: #{script}
            executable: 86
          register: r
          ignore_errors: true
        - debug:
            msg: "{{ r.rc }} | {{ r.stderr }}"
      YAML

    status, output = run_playbook(src_dir, playbook)

    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("\"rc\": 127")
    output.to_s.must_include("\"stderr\": \"/bin/sh: 1: 86: not found\\n\"")
    output.to_s.wont_include("Local execution failed")
    output.to_s.must_include("127 | /bin/sh: 1: 86: not found")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "still runs a valid executable: prefix through the same shell wrapper" do
    src_dir = File.tempname("script-valid-executable")
    Dir.mkdir_p(src_dir)
    script = File.join(src_dir, "x.sh")
    File.write(script, "#!/bin/sh\necho interpreter-ran \"$@\"\n")
    File.chmod(script, 0o755)

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
        - name: script with valid executable
          ansible.builtin.script:
            cmd: #{script} via-executable
            executable: /bin/sh
          register: r
        - debug:
            msg: "{{ r.stdout }} {{ r.rc }}"
      YAML

    status, output = run_playbook(src_dir, playbook)

    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("changed: [localhost]")
    output.to_s.must_include("interpreter-ran via-executable\\n 0")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
