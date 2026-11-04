require "../minitest_helper"
require "json"

# Issue #838: ansible-core 2.19's DataLoader warns on duplicate mapping
# keys when it loads a role's meta/main.yml, at load time, on STDERR,
# before any PLAY output - even when the meta has no `dependencies:` and
# no unknown top-level keys (mmagonde.ansible_jenkins_swarm_agent ships
# `license:` twice inside galaxy_info). krikri only scanned meta files for
# duplicates on the paths that needed the source map anyway (dependency
# parsing, unknown-key validation), so a dependency-less valid meta stayed
# silent. These specs drive the real binary to pin the load-time STDERR
# shape end to end. The warning is cosmetic: the last value still wins.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_role_playbook(work : String) : {Process::Status, String, String}
  playbook = File.join(work, "site.yml")

  stdout = IO::Memory.new
  stderr = IO::Memory.new
  status = Process.run(
    BINARY,
    ["-i", File.join(__DIR__, "..", "fixtures", "inventory-localhost-local.ini"), playbook],
    output: stdout,
    error: stderr,
    chdir: work
  )
  {status, stdout.to_s, stderr.to_s}
end

describe "duplicate mapping key warning for role meta/main.yml (issue 838)" do
  it "warns once for a duplicate key in a meta without dependencies, last value wins" do
    work = PluginSpecHelper.tmp_path("dup-key-meta")
    FileUtils.rm_rf(work)
    Dir.mkdir_p(work)
    role_dir = File.join(work, "roles", "metaduprole")
    Dir.mkdir_p(File.join(role_dir, "meta"))
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "meta", "main.yml"), <<-YAML
      galaxy_info:
        author: someone
        description: duplicate license test
        license: BSD
        license: Apache-2.0
      dependencies: []
      YAML
    )
    File.write(File.join(role_dir, "tasks", "main.yml"), <<-YAML
      ---
      - name: show value
        ansible.builtin.debug:
          msg: hello
      YAML
    )
    File.write(File.join(work, "site.yml"), <<-YAML
      ---
      - hosts: localhost
        gather_facts: false
        roles:
          - metaduprole
      YAML
    )

    status, stdout, stderr = run_role_playbook(work)
    status.success?.must_equal(true)

    # Ansible warns once per duplicate occurrence, at load time, on STDERR.
    stderr.scan("Found duplicate mapping key 'license'").size.must_equal(1)
    stderr.must_include("Origin: #{File.expand_path(File.join(role_dir, "meta", "main.yml"))}:5:3")
    stderr.must_include("Using last defined value only.")

    # The warning is cosmetic - the run still proceeds normally.
    stdout.must_include("hello")
  end

  it "still warns exactly once when the meta has dependencies to parse" do
    # The dependency loop was already the one cached_source_map caller for
    # meta files; pin that the unconditional scan doesn't double-warn.
    work = PluginSpecHelper.tmp_path("dup-key-meta-deps")
    FileUtils.rm_rf(work)
    Dir.mkdir_p(work)
    role_dir = File.join(work, "roles", "metadupdeps")
    dep_dir = File.join(work, "roles", "metadupdep")
    Dir.mkdir_p(File.join(role_dir, "meta"))
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    Dir.mkdir_p(File.join(dep_dir, "tasks"))
    File.write(File.join(role_dir, "meta", "main.yml"), <<-YAML
      galaxy_info:
        author: someone
        license: BSD
        license: Apache-2.0
      dependencies:
        - metadupdep
      YAML
    )
    File.write(File.join(role_dir, "tasks", "main.yml"), "---\n- debug:\n    msg: from-role\n")
    File.write(File.join(dep_dir, "tasks", "main.yml"), "---\n- debug:\n    msg: from-dep\n")
    File.write(File.join(work, "site.yml"), "---\n- hosts: localhost\n  gather_facts: false\n  roles:\n    - metadupdeps\n")

    status, _stdout, stderr = run_role_playbook(work)
    status.success?.must_equal(true)
    stderr.scan("Found duplicate mapping key 'license'").size.must_equal(1)
  end
end
