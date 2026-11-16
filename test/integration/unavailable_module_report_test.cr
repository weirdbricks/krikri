require "../minitest_helper"

# A task whose module krikri doesn't implement is skipped and the run exits 4.
# The exit-4 run also names each skipped module in the same "uses unimplemented
# plugin: <module>" form as the parse-time warning, so the role tester can tell a
# divergence caused by an untracked community module (COMMUNITY_MODULE_MISSING)
# from a real gap. The parse-time warning skips unavailable modules, so this
# line is the only place the name shows up.
#
# The controller collection fixture makes the name resolve as in
# unavailable_module_args_finalization_test.cr, so the result does not depend on
# what community.general the test machine has installed.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "unavailable module report" do
  it "names each skipped unavailable module after the run and exits 4" do
    playbook = File.tempname("unavailable-module-report", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: subscribe
            community.general.redhat_subscription:
              state: present
          - name: subscribe again
            community.general.redhat_subscription:
              state: present
      YAML
    fixture_root = File.tempname("unavailable-module-report-collections")
    module_dir = File.join(fixture_root, "ansible_collections", "community", "general", "plugins", "modules")
    FileUtils.mkdir_p(module_dir)
    File.write(File.join(module_dir, "redhat_subscription.py"), "#!/usr/bin/python\n")
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output,
      env: {"ANSIBLE_COLLECTIONS_PATH" => fixture_root})

    status.exit_code.must_equal(4)
    output.to_s.lines.count(&.includes?("uses unimplemented plugin: community.general.redhat_subscription")).must_equal(1)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    FileUtils.rm_r(fixture_root) if fixture_root && Dir.exists?(fixture_root)
  end

  # fgierlinger.docker in check mode (issue #1359): the role's `portage:` task
  # is an untracked community module, and the task that fails afterwards (the
  # role's `service:` for a docker that was never installed; a plain `fail:`
  # here keeps this independent of the test host) must not downgrade the exit
  # status to a failed host's 2 - ansible-playbook refuses an unresolvable
  # module with 4, so 4 is the code the role tester reads to call such a role
  # COMMUNITY_MODULE_MISSING instead of a krikri gap.
  it "keeps the report and exits 4 when a later task fails" do
    playbook = File.tempname("unavailable-module-then-failure", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: install docker
            portage:
              state: present
              package: app-emulation/docker
          - name: enable docker
            ansible.builtin.fail:
              msg: boom
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "--check", playbook], output: output, error: output)

    status.exit_code.must_equal(4)
    output.to_s.must_include("failed=1")
    output.to_s.lines.count(&.includes?("uses unimplemented plugin: portage")).must_equal(1)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
