require "../minitest_helper"
require "file_utils"

# `copy:` with `force: false` aimed at a destination that already exists.
#
# Ansible's copy ACTION plugin reads the dest stat first and takes its
# exists-and-not-force branch (copy.py:280-283), returning BEFORE the copy
# module - and with it the module's argument spec - ever runs. A task that
# carries an invented option (`dest_bogus:`), or a bool spelled wrong
# (`backup: notabool`), therefore reports ok: only a run that really moves
# bytes reaches the spec. Found by krikri-playbook-generator (issue #1805:
# a generated `content:` + `force: false` copy carried two invented
# options and real ansible reported ok where krikri failed the task).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def write_force_false_playbook(path : String, dest : String, force : String) : Nil
  File.write(path, <<-YAML)
    - name: repro
      hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - name: Copy with invented options
          ansible.builtin.copy:
            content: kpg line without newline
            dest: #{dest}
            directory_mode: "0755"
            force: #{force}
            local_follow: true
            remote_src: false
            unsafe_writes: true
            validate: /bin/true %s
            dest_bogus: #{dest}
            group_bogus: root
          register: kpg_task_0
          ignore_errors: true
        - name: Kpg successor
          ansible.builtin.debug:
            msg: kpg-successor
          when: kpg_task_0 is succeeded
  YAML
end

describe "copy: force false against an existing dest" do
  it "reports ok instead of rejecting an invented option" do
    dest = PluginSpecHelper.tmp_path("force-false-bogus.txt")
    File.write(dest, "kpg locked dest\nsecond line\n")
    File.chmod(dest, 0o444)
    playbook = PluginSpecHelper.tmp_path("force-false-bogus.yml")
    write_force_false_playbook(playbook, dest, "false")

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true, output.to_s)
    out = output.to_s
    out.wont_include("Unsupported parameters")
    out.wont_include("ERROR")
    out.wont_include("skipping:")
    out.must_include("ok: [localhost]")
    out.must_include("kpg-successor")
    # force: false leaves the existing file completely alone.
    File.read(dest).must_equal("kpg locked dest\nsecond line\n")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "still rejects an invented option when the module would really run" do
    # A missing dest takes _copy_file's transfer branch, so the module runs
    # and its spec does reject the same invented option.
    dest = PluginSpecHelper.tmp_path("force-false-bogus-written.txt")
    File.delete(dest) if File.exists?(dest)
    playbook = PluginSpecHelper.tmp_path("force-false-bogus-written.yml")
    write_force_false_playbook(playbook, dest, "false")

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true, output.to_s)
    out = output.to_s
    out.must_include("Unsupported parameters for (ansible.legacy.copy) module: dest_bogus, group_bogus.")
    out.wont_include("kpg-successor")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "keeps the no-op's registered result to dest/src/changed" do
    # The action's early return discards _copy_file's own result dict, the
    # only place a diff was ever seeded, so the registered no-op carries no
    # diff key (live-verified vs ansible-core 2.21.6 - issue #1805).
    dest = PluginSpecHelper.tmp_path("force-false-shape.txt")
    PluginSpecHelper.run("copy", {"content" => "kept\n", "dest" => dest})

    result = PluginSpecHelper.run("copy", {"content" => "other\n", "dest" => dest, "force" => "false"})

    result["changed"].as_bool.must_equal(false)
    result.as_h.keys.must_equal(["dest", "src", "changed"])
    File.read(dest).must_equal("kept\n")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "does not strict-check a bool option on the no-op path" do
    # The module's own `type: bool` conversions never run either, so a
    # misspelled backup: is not a failure here ...
    dest = PluginSpecHelper.tmp_path("force-false-bool.txt")
    PluginSpecHelper.run("copy", {"content" => "kept\n", "dest" => dest})

    result = PluginSpecHelper.run("copy",
      {"content" => "other\n", "dest" => dest, "force" => "false", "backup" => "notabool"})
    result["failed"]?.try(&.as_bool).wont_equal(true)
    File.read(dest).must_equal("kept\n")

    # ... while a run that really moves bytes reaches the spec and fails.
    other = PluginSpecHelper.tmp_path("force-false-bool-written.txt")
    File.delete(other) if File.exists?(other)
    failed = PluginSpecHelper.run("copy",
      {"content" => "other\n", "dest" => other, "force" => "false", "backup" => "notabool"})
    failed["failed"].as_bool.must_equal(true)
    failed["msg"].as_s.must_include("argument 'backup' is of type str and we were unable to convert to bool")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
    File.delete(other) if other && File.exists?(other)
  end
end
