require "../minitest_helper"

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
end
