require "../minitest_helper"
require "file_utils"

# script: is an ACTION plugin in ansible-core: the action runs the
# transferred file itself and returns its own result dict, so a non-zero
# exit reaches the executor's result scrutiny as an ACTION-context error -
# the [ERROR] header reads "Task failed: Action failed: non-zero return
# code" (live-verified vs 2.19.11), never the "Module failed:" wording a
# module-reflected result would get. The fatal dump and the registered
# var stay untouched (the internal marker keys are stripped by the same
# pipeline that strips every `_ansible_*` key).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "script non-zero-exit Action failed header" do
  it "renders the bare-spelling failure as an action-level failure" do
    script = File.tempname("krikri-script-fail", ".sh")
    File.write(script, "#!/bin/sh\nexit 7\n")
    File.chmod(script, 0o755)
    playbook = File.tempname("script-action-fail", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: fail script
            script: #{script}
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Action failed: non-zero return code")
    text.must_include("Origin: #{playbook}:4:7")
    # The fatal dump and the registered shape are unchanged: only the
    # [ERROR] header differs from the module-failure wording.
    text.must_include(%(FAILED! => {"changed": true, "msg": "non-zero return code", "rc": 7, "stderr": "", "stderr_lines": [], "stdout": "", "stdout_lines": []}))
    refute(text.includes?("Module failed: non-zero return code"))
    refute(text.includes?("_ansible_action_level"))
    refute(text.includes?("_ansible_error_detail"))
  ensure
    File.delete(script) if script && File.exists?(script)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "renders the FQCN spelling the same way and keeps the registered var clean" do
    script = File.tempname("krikri-script-fail", ".sh")
    File.write(script, "#!/bin/sh\nexit 7\n")
    File.chmod(script, 0o755)
    playbook = File.tempname("script-action-fail-fqcn", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: fail script fqcn
            ansible.builtin.script: #{script}
            ignore_errors: true
            register: r
          - debug:
              msg: "{{ r | to_json }}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Action failed: non-zero return code")
    # The registered dump mirrors real's: no `_ansible_*` marker survives
    # register - only the module's own wire keys.
    text.must_include(%q(\"failed\": true))
    text.must_include(%q(\"msg\": \"non-zero return code\"))
    refute(text.includes?("_ansible_action_level"))
    refute(text.includes?("_ansible_error_detail"))
  ensure
    File.delete(script) if script && File.exists?(script)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Real's argspec failures (raise inside validate_argument_spec) render
  # WITHOUT the "Action failed." segment, and krikri already matched that -
  # the action-level marking is scoped to a result the script's own
  # execution produced (it carries an rc), never to the validation class.
  it "keeps the argspec mutual-exclusion failure's plain header" do
    playbook = File.tempname("script-action-fail-argspec", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: conflicting args
            script:
              cmd: /bin/true
              _raw_params: /bin/true
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: parameters are mutually exclusive: _raw_params|cmd")
    refute(text.includes?("Action failed: parameters are mutually exclusive"))
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # The until:/retries: attempt loop keeps retrying a failing script -
  # real's action-context raise for a RETURNED dict happens outside the
  # attempt loop, so unlike a raised action failure (unarchive et al.,
  # issue #131) the RETRYING line and the attempts key both survive.
  it "still retries a failing script under until/retries" do
    script = File.tempname("krikri-script-fail", ".sh")
    File.write(script, "#!/bin/sh\nexit 7\n")
    File.chmod(script, 0o755)
    playbook = File.tempname("script-action-fail-until", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: retried script
            script: #{script}
            until: false
            retries: 1
            delay: 0
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("FAILED - RETRYING: [localhost]:")
    text.must_include("[ERROR]: Task failed: Action failed: non-zero return code")
    text.must_include(%({"attempts": 1, "changed": true, "msg": "non-zero return code", "rc": 7, "stderr": "", "stderr_lines": [], "stdout": "", "stdout_lines": []}))
  ensure
    File.delete(script) if script && File.exists?(script)
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Issue #1016 (kpg 000024-multi-script-happy): real's script action
  # stages its transferred copy under the target's
  # <remote_tmp>/ansible-tmp-<ts>-<pid>-<rand>/<basename> and runs THAT,
  # over ansible_connection=local too (live-verified vs 2.19.11) - so the
  # script's own $0, quoted by every shell error line, reads the staged
  # path, never the controller-side source path. krikri ran the source in
  # place and every failing script's stderr diverged.
  it "runs a local script from its ansible-tmp staging copy so shell errors quote the staged path (issue #1016)" do
    src_dir = File.tempname("script-local-staging")
    Dir.mkdir_p(src_dir)
    remote_tmp = File.join(src_dir, "remote_tmp")
    fixture = File.join(src_dir, "src.txt")
    File.write(fixture, "kpg\nsecond\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          ansible_remote_tmp: #{remote_tmp}
        tasks:
          - name: failing fixture script
            ansible.builtin.script:
              cmd: #{fixture}
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_match(%r{"stderr": "#{Regex.escape(remote_tmp)}/ansible-tmp-[\d.\-]+/src\.txt: 1: kpg: not found})
    refute(text.includes?(fixture))
    # ansible's script.py removes the whole per-task tmp dir in its
    # finally clause - the staged copy must leave no trace either.
    Dir.children(remote_tmp).must_equal([] of String)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
