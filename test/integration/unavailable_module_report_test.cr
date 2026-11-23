require "../minitest_helper"

# A task whose module krikri doesn't implement is skipped and the run exits 4.
# The exit-4 run also names each skipped task and module in the same
# "Task '<name>' uses unimplemented plugin: <module>" form as the parse-time
# warning, so the role tester can tell a divergence caused by an untracked
# community module (COMMUNITY_MODULE_MISSING) from a real gap - and can tie the
# warning to the divergent block it explains, because the task name is what its
# diff carries. The parse-time warning skips unavailable modules, so this line
# is the only place they show up.
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
    # One line per TASK+module: the two tasks share a module but keep their own
    # names, so the log says which task was dropped, not just which module.
    output.to_s.lines.count(&.includes?("uses unimplemented plugin: community.general.redhat_subscription")).must_equal(2)
    output.to_s.must_include("Task 'subscribe' uses unimplemented plugin: community.general.redhat_subscription")
    output.to_s.must_include("Task 'subscribe again' uses unimplemented plugin: community.general.redhat_subscription")
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
    output.to_s.must_include("Task 'install docker' uses unimplemented plugin: portage")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # artem_shestakov.elasticsearch_exporter's community.general.consul task
  # (issue #1647): the module declares AnsibleModule(supports_check_mode=False),
  # so a --check run is a plain skip in real - nothing runs, and the exit code
  # stays 0. Registering it for the engine-limit report added a "uses
  # unimplemented plugin" line and exit 4 for work real never did either.
  # Without --check the same task stays an unported module and its report must
  # survive, so the run is compared both ways here.
  it "does not report a module real skips before running under --check" do
    playbook = File.tempname("unavailable-module-check-skip", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - name: Register Elasticsearch service with the local consul agent
            community.general.consul:
              host: "localhost"
              service_name: "elasticsearch_exporter"
              service_port: 9114
              interval: "60s"
              tags:
                - exporter
          - name: Register again by short name
            consul:
              host: "localhost"
              service_name: "elasticsearch_exporter"
      YAML
    fixture_root = File.tempname("unavailable-module-check-skip-collections")
    module_dir = File.join(fixture_root, "ansible_collections", "community", "general", "plugins", "modules")
    FileUtils.mkdir_p(module_dir)
    File.write(File.join(module_dir, "consul.py"), "#!/usr/bin/python\n")
    check_output = IO::Memory.new
    check_status = Process.run(BINARY, ["-i", INVENTORY, "--check", playbook], output: check_output, error: check_output,
      env: {"ANSIBLE_COLLECTIONS_PATH" => fixture_root})
    real_output = IO::Memory.new
    real_status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: real_output, error: real_output,
      env: {"ANSIBLE_COLLECTIONS_PATH" => fixture_root})

    check_status.exit_code.must_equal(0)
    check_output.to_s.wont_include("uses unimplemented plugin")
    check_output.to_s.must_include("skipped=2")
    real_status.exit_code.must_equal(4)
    real_output.to_s.must_include("uses unimplemented plugin: community.general.consul")
    real_output.to_s.must_include(
      "Task 'Register Elasticsearch service with the local consul agent' uses unimplemented plugin: community.general.consul")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    FileUtils.rm_rf(fixture_root) if fixture_root && Dir.exists?(fixture_root)
  end

  # tansudasli.gcp_instances' gcp_compute_* tasks (issue #1744): google.cloud
  # generates every module from GcpModule without passing
  # supports_check_mode, and only the read-only `_info` readers opt in - so a
  # --check run of a mutating `gcp_*` task is a plain skip in real (exit 0),
  # while an `_info` reader really runs there and keeps the exit-4 report.
  # Both spellings a task can carry are checked (bare short name and FQCN).
  # Outside --check every one of them keeps its report.
  it "does not report google.cloud modules real skips under --check" do
    playbook = File.tempname("unavailable-module-gcp-check", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: create boot-disk
            gcp_compute_disk:
              name: boot-disk-01
              zone: europe-west4-a
              project: sandbox
              auth_kind: serviceaccount
              scopes:
                - https://www.googleapis.com/auth/compute
              state: present
          - name: create a static-IP address
            google.cloud.gcp_compute_address:
              state: present
              name: ip-01
              project: sandbox
              region: europe-west4
              auth_kind: serviceaccount
          - name: list instances
            google.cloud.gcp_compute_instance_info:
              zone: europe-west4-a
              project: sandbox
              auth_kind: serviceaccount
      YAML
    fixture_root = File.tempname("unavailable-module-gcp-collections")
    module_dir = File.join(fixture_root, "ansible_collections", "google", "cloud", "plugins", "modules")
    FileUtils.mkdir_p(module_dir)
    {"gcp_compute_disk", "gcp_compute_address", "gcp_compute_instance_info"}.each do |module_name|
      File.write(File.join(module_dir, "#{module_name}.py"), "#!/usr/bin/python\n")
    end
    check_output = IO::Memory.new
    check_status = Process.run(BINARY, ["-i", INVENTORY, "--check", playbook], output: check_output, error: check_output,
      env: {"ANSIBLE_COLLECTIONS_PATH" => fixture_root})
    real_output = IO::Memory.new
    real_status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: real_output, error: real_output,
      env: {"ANSIBLE_COLLECTIONS_PATH" => fixture_root})

    check_output.to_s.wont_include("uses unimplemented plugin: gcp_compute_disk")
    check_output.to_s.wont_include("uses unimplemented plugin: google.cloud.gcp_compute_address")
    check_output.to_s.must_include("Task 'list instances' uses unimplemented plugin: google.cloud.gcp_compute_instance_info")
    check_status.exit_code.must_equal(4)
    real_output.to_s.must_include("Task 'create boot-disk' uses unimplemented plugin: gcp_compute_disk")
    real_output.to_s.must_include("Task 'create a static-IP address' uses unimplemented plugin: google.cloud.gcp_compute_address")
    real_output.to_s.must_include("Task 'list instances' uses unimplemented plugin: google.cloud.gcp_compute_instance_info")
    real_status.exit_code.must_equal(4)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    FileUtils.rm_rf(fixture_root) if fixture_root && Dir.exists?(fixture_root)
  end
end
