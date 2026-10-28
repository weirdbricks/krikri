require "file_utils"
require "../minitest_helper"

# Runs the compiled binary against a real playbook, since this is about
# plugins/template.cr's own filesystem staging behavior, not reachable
# from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Found via bertvv.dhcp round 312 and re-confirmed via robertdebock.cups
# (issue #615): template:'s `validate:` staging must sit where Ansible
# stages its own candidate - a per-run ansible-tmp-<...> directory under
# the remote user's ~/.ansible/tmp (Ansible's remote_tmp default), with
# the candidate named .source + dest's extension. A validator confined
# by AppArmor/SELinux (cupsd's profile, via abstractions/user-tmp, only
# allows /tmp - NOT ~/.ansible/tmp) sees a different outcome when the
# candidate is staged elsewhere, and the final move goes through
# FileUtils.mv (stdlib) so a destination on a different filesystem than
# the home-dir stage doesn't reintroduce the earlier cross-device
# File.rename bug (see KNOWN_MISSING.md and template.cr's own comment on
# run_dir/temp_file).
describe "template: with validate:" do
  it "renders successfully when the validate: command passes" do
    src = File.tempname("template-validate-src", ".j2")
    dest = File.tempname("template-validate-dest")
    playbook = File.tempname("template-validate", ".yml")
    File.write(src, "hello {{ msg }}\n")

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          msg: world
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
              validate: "cat %s"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    File.read(dest).must_equal("hello world\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "fails the task and removes the per-run staging dir, as real's cleanup does, when validate: fails" do
    src = File.tempname("template-validate-src", ".j2")
    dest_dir = Dir.tempdir + "/krikri-template-validate-dest-dir-#{Random::Secure.hex(4)}"
    Dir.mkdir_p(dest_dir)
    dest = File.join(dest_dir, "out.conf")
    playbook = File.tempname("template-validate-fail", ".yml")
    File.write(src, "hello {{ msg }}\n")

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          msg: world
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
              validate: "false %s"
      YAML

    # Private HOME: the snapshot below must see only THIS run's staging,
    # not a concurrently running test's spawn - every krikri-playbook in
    # the suite shares the real home's ~/.ansible/tmp otherwise (same
    # pattern as the issue-615 spec below).
    home = PluginSpecHelper.tmp_path("validate-cleanup-home-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(home)
    ansible_tmp = File.join(home, ".ansible", "tmp")

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output,
      env: {"HOME" => home})

    status.success?.must_equal(false)
    # Real copy.py's validate site (the template module runs through it)
    # fails with fail_json(msg="failed to validate", exit_status=rc,
    # stdout=out, stderr=err) - the wording is "failed to validate",
    # never "Validation failed" (live-verified vs 2.19.11: the fatal
    # dump is {"changed": false, "checksum": ..., "exit_status": 1,
    # "msg": "failed to validate", "stderr": "", "stderr_lines": [],
    # "stdout": "", "stdout_lines": []}).
    output.to_s.must_include("\"msg\": \"failed to validate\"")
    output.to_s.must_include("\"exit_status\": 1")
    # Real removes its per-run tmp dir on every path (do_cleanup_files
    # `rm -f -r`s it even after a failed validate:), so the private
    # home's ~/.ansible/tmp holds no leftover ansible-tmp dir after the
    # task fails.
    (Dir.exists?(ansible_tmp) ? Dir.children(ansible_tmp) : [] of String)
      .select { |entry| entry.starts_with?("ansible-") }
      .must_equal([] of String)
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    FileUtils.rm_rf(home) if home && Dir.exists?(home)
    FileUtils.rm_rf(dest_dir) if dest_dir
  end

  it "hands validate: a candidate staged under ~/.ansible/tmp with Ansible's .source naming" do
    # Issue #615 (robertdebock.cups): the observable difference was WHERE
    # the validator's %s path pointed - real ansible-playbook stages the
    # candidate as .source<dest extension> inside a per-run
    # ~/.ansible/tmp/ansible-tmp-<...> directory, the old krikri staging
    # was /tmp/.krikri-playbook-template-<hex>.tmp. The validate command
    # records the path it is handed ($0 after the %s substitution) so the
    # assertion reads the actual path, not a side effect.
    home = PluginSpecHelper.tmp_path("issue615-home-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(home)
    capture = PluginSpecHelper.tmp_path("issue615-captured-path-#{Random::Secure.hex(4)}")
    src = File.tempname("template-validate-src", ".j2")
    dest_dir = Dir.tempdir + "/krikri-template-validate-dest-dir-#{Random::Secure.hex(4)}"
    Dir.mkdir_p(dest_dir)
    dest = File.join(dest_dir, "cupsd.conf")
    playbook = File.tempname("template-validate-path", ".yml")
    File.write(src, "hello {{ msg }}\n")

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          msg: world
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
              validate: 'sh -c ''printf "%s" "$0" > #{capture}'' %s'
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output,
      env: {"HOME" => home})

    status.success?.must_equal(true, output.to_s)
    File.read(dest).must_equal("hello world\n")
    recorded = File.read(capture)
    # Ansible's own location and name: under the run user's ~/.ansible/tmp,
    # inside an ansible-tmp-<...> dir, with dest's extension kept.
    recorded.starts_with?(File.join(home, ".ansible", "tmp", "ansible-tmp-")).must_equal(true)
    recorded.ends_with?("/.source.conf").must_equal(true)
    recorded.includes?("/tmp/.krikri-playbook-template-").must_equal(false)
    # The per-run dir is removed on every path, success included (real's
    # do_cleanup_files), so the recorded parent no longer exists.
    File.exists?(File.dirname(recorded)).must_equal(false)
  ensure
    FileUtils.rm_rf(home) if home && Dir.exists?(home)
    File.delete(capture) if capture && File.exists?(capture)
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    FileUtils.rm_rf(dest_dir) if dest_dir
  end

  it "fails before running anything when validate: has no %s, with copy.py's message" do
    src = File.tempname("template-validate-src", ".j2")
    dest = File.tempname("template-validate-dest")
    playbook = File.tempname("template-validate-nos", ".yml")
    File.write(src, "hello {{ msg }}\n")

    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          msg: world
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
              validate: "false"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    output.to_s.must_include("validate must contain %s")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
