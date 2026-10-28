require "../minitest_helper"
require "json"

# Issue #193: ansible-core 2.19 warns on duplicate top-level mapping keys
# in EVERY vars-style file it loads at role-load time (defaults/main.yml,
# vars/main.yml, include_vars files), on STDERR, before any PLAY output:
#
#   [WARNING]: Found duplicate mapping key 'ws_vhost_path'.
#   Origin: <abs>/defaults/main.yml:4:1
#   ...
#   Using last defined value only.
#
# krikri only warned for meta/tasks files (the paths that go through the
# source-map scan for Origins) and stayed silent for vars files; these
# specs drive the real binary so the load-time STDERR shape is pinned
# end to end. The warning is cosmetic: the last defined value still wins.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_role_playbook(work : String, role_name : String = "duprole") : {Process::Status, String, String}
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

private def write_role(work : String, role_name : String, defaults_body : String, file : String = "main.yml") : Nil
  role_dir = File.join(work, "roles", role_name)
  Dir.mkdir_p(File.join(role_dir, "defaults"))
  Dir.mkdir_p(File.join(role_dir, "tasks"))
  File.write(File.join(role_dir, "defaults", file), defaults_body)
  File.write(File.join(role_dir, "tasks", "main.yml"), <<-YAML
    ---
    - name: show value
      ansible.builtin.debug:
        msg: "{{ ws_vhost_path }}"
    YAML
  )
  File.write(File.join(work, "site.yml"), <<-YAML
    ---
    - hosts: localhost
      gather_facts: false
      roles:
        - #{role_name}
    YAML
  )
end

describe "duplicate mapping key warning for role vars files (issue 193)" do
  it "warns exactly once on stderr for a duplicate key in defaults/main.yml, last value wins" do
    work = PluginSpecHelper.tmp_path("dup-key-defaults")
    FileUtils.rm_rf(work)
    Dir.mkdir_p(work)
    write_role(work, "duprole", <<-YAML)
      ---
      ws_vhost_path: first-value
      other: kept
      ws_vhost_path: final-value
      YAML

    status, stdout, stderr = run_role_playbook(work)
    status.success?.must_equal(true)

    # Ansible warns once per duplicate occurrence, at load time, on STDERR.
    stderr.scan("Found duplicate mapping key 'ws_vhost_path'").size.must_equal(1)
    stderr.must_include("Origin: #{File.expand_path(File.join(work, "roles", "duprole", "defaults", "main.yml"))}:4:1")
    stderr.must_include("Using last defined value only.")

    # The warning is cosmetic - the last defined value still wins.
    stdout.must_include("final-value")
    stdout.wont_include("first-value")
  end

  it "warns for the defaults/main/ directory form too" do
    work = PluginSpecHelper.tmp_path("dup-key-defaults-dir")
    FileUtils.rm_rf(work)
    Dir.mkdir_p(work)
    role_dir = File.join(work, "roles", "dupdirrole")
    Dir.mkdir_p(File.join(role_dir, "defaults", "main"))
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "defaults", "main", "a.yml"), "ws_vhost_path: one\nws_vhost_path: two\n")
    File.write(File.join(role_dir, "tasks", "main.yml"), "---\n- debug:\n    msg: \"{{ ws_vhost_path }}\"\n")
    File.write(File.join(work, "site.yml"), "---\n- hosts: localhost\n  gather_facts: false\n  roles:\n    - dupdirrole\n")

    status, _stdout, stderr = run_role_playbook(work, "dupdirrole")
    status.success?.must_equal(true)
    stderr.scan("Found duplicate mapping key 'ws_vhost_path'").size.must_equal(1)
  end

  it "does not raise (or warn) for a vars file in JSON form" do
    # Ansible's loader takes the json path for .json vars files, so its
    # YAML-constructor duplicate-key warning never fires for them; krikri
    # must at minimum load the file without raising.
    work = PluginSpecHelper.tmp_path("dup-key-defaults-json")
    FileUtils.rm_rf(work)
    Dir.mkdir_p(work)
    role_dir = File.join(work, "roles", "jsonrole")
    Dir.mkdir_p(File.join(role_dir, "defaults"))
    Dir.mkdir_p(File.join(role_dir, "tasks"))
    File.write(File.join(role_dir, "defaults", "main.json"), "{\"ws_vhost_path\": \"json-value\"}\n")
    File.write(File.join(role_dir, "tasks", "main.yml"), "---\n- debug:\n    msg: \"{{ ws_vhost_path }}\"\n")
    File.write(File.join(work, "site.yml"), "---\n- hosts: localhost\n  gather_facts: false\n  roles:\n    - jsonrole\n")

    status, stdout, stderr = run_role_playbook(work, "jsonrole")
    status.success?.must_equal(true)
    stderr.wont_include("Found duplicate mapping key")
    stdout.must_include("json-value")
  end
end
