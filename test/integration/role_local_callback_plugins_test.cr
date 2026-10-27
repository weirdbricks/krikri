require "../minitest_helper"
require "file_utils"
require "../../src/krikri/python_filter_runner"

# Ansible's callback loader imports every STATICALLY loaded role's
# callback_plugins/*.py at role load and warns once per unloadable file on
# stderr, before the first PLAY banner (issue #596: ovirt.disaster-recovery
# 1.3.0's callback_plugins/stdout.py, whose `from __future__ import` sits
# after other imports -> SyntaxError). A role reached only through
# include_role: prints nothing (live-verified vs 2.19.11). krikri never
# looked at callback_plugins/ at all. See
# PythonFilterRunner#warn_unloadable_role_callback_plugins.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def write_role_with_broken_callback(root : String, name : String = "broken") : String
  Dir.mkdir_p(File.join(root, "roles", name, "callback_plugins"))
  Dir.mkdir_p(File.join(root, "roles", name, "tasks"))
  # Issue #596's exact shape: a `from __future__` import after a plain
  # import - the SyntaxError text Python reports is what Ansible's
  # "cannot load:" tail carries verbatim.
  broken = File.join(root, "roles", name, "callback_plugins", "stdout.py")
  File.write(broken, "import os\n\nfrom __future__ import annotations\n")
  File.write(File.join(root, "roles", name, "tasks", "main.yml"), <<-YAML)
    - name: ok
      ansible.builtin.debug:
        msg: hi
    YAML
  broken
end

private def run_playbook(root : String, playbook_body : String) : {Process::Status, String}
  File.write(File.join(root, "pb.yml"), playbook_body)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)
  {status, output.to_s}
end

describe "role callback_plugins/*.py broken import warning" do
  serial! # replaces PythonFilterRunner's process-wide warning sink

  it "warns exactly once with Ansible's wording, before PLAY, for a roles:-loaded role" do
    root = File.tempname("callback-broken-roles")
    broken = write_role_with_broken_callback(root)
    # `tags: [never]` does not suppress it: Ansible loads play roles at
    # parse time regardless of what would ever run from them
    # (live-verified vs 2.19.11).
    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - role: broken
            tags: [never]
      YAML

    status.success?.must_equal(true, output)
    lines = output.lines
    warnings = lines.select(&.starts_with?("[WARNING]: Skipping plugin ("))
    warnings.size.must_equal(1, output)
    warnings.first.must_equal(
      "[WARNING]: Skipping plugin (#{File.expand_path(broken)}), cannot load: from __future__ imports must occur at the beginning of the file (stdout.py, line 3)"
    )
    first_play = lines.index { |line| line.starts_with?("PLAY [") }
    first_play.wont_be_nil
    warning_index = lines.index!(warnings.first)
    assert warning_index < first_play.not_nil!, output
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "prints nothing for a role reached only through include_role:" do
    root = File.tempname("callback-broken-include-role")
    write_role_with_broken_callback(root)
    status, output = run_playbook(root, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - ansible.builtin.include_role:
              name: broken
      YAML

    status.success?.must_equal(true, output)
    output.wont_include("Skipping plugin", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "keeps the once-per-file-per-run dedup across repeated static loads" do
    root = PluginSpecHelper.tmp_path("callback-warning-dedup")
    broken = write_role_with_broken_callback(root)

    captured = IO::Memory.new
    previous = Krikri::PythonFilterRunner.warning_sink
    begin
      Krikri::PythonFilterRunner.warning_sink = captured
      role_dir = File.join(root, "roles", "broken")
      Krikri::PythonFilterRunner.warn_unloadable_role_callback_plugins(role_dir)
      # the same role's second static load (an import_role: of a play
      # role, a second play's identical entry) must not repeat it
      Krikri::PythonFilterRunner.warn_unloadable_role_callback_plugins(role_dir)
    ensure
      Krikri::PythonFilterRunner.warning_sink = previous
      Krikri::PythonFilterRunner.unregister_role_plugin_roots_under(root)
    end

    lines = captured.to_s.lines
    lines.size.must_equal(1, captured.to_s)
    lines.first.must_equal(
      "[WARNING]: Skipping plugin (#{File.expand_path(broken)}), cannot load: from __future__ imports must occur at the beginning of the file (stdout.py, line 3)"
    )
  end
end
