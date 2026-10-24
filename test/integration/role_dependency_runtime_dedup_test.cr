require "../minitest_helper"
require "file_utils"

# Real ansible's dedup decision for a reached-again identical meta/main.yml
# dependency is RUN-time and per host (issue #320): the strategy skips the
# second invocation only when an EARLIER identical invocation actually
# completed a non-skipped task for that host (role._had_task_run is set on
# ok/changed/failed results, never on a skip). krikri used to collapse the
# duplicate at load time instead, so a shared dependency whose every task
# was skipped (`{ role: c, when: ansible_distribution == 'MacOSX' }` on a
# Linux host) printed its skipping: block once where real prints it on
# every reach, and the fix moved the whole decision into the executor.
#
# The silent skip produces NO output at all - no banner, no `skipping:`
# line, no recap entry - the way real silently consumes an already-run
# role's task batch.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def write_runtime_dedup_role(src_dir : String, name : String, shared_meta : String? = nil) : Nil
  Dir.mkdir_p(File.join(src_dir, "roles", name, "tasks"))
  Dir.mkdir_p(File.join(src_dir, "roles", name, "meta"))
  File.write(File.join(src_dir, "roles", name, "meta", "main.yml"), shared_meta) if shared_meta
  if name == "shared"
    File.write(File.join(src_dir, "roles", name, "tasks", "main.yml"), <<-YAML)
      - name: shared task
        debug:
          msg: shared ran
      YAML
  else
    File.write(File.join(src_dir, "roles", name, "tasks", "main.yml"), <<-YAML)
      - name: #{name} task
        debug:
          msg: #{name} ran
      YAML
    File.write(File.join(src_dir, "roles", name, "meta", "main.yml"), <<-YAML)
      dependencies:
        - role: shared
          when: run_dep
      YAML
  end
end

private def run_runtime_dedup_playbook(src_dir : String, run_dep : String) : String
  playbook = File.join(src_dir, "pb.yml")
  File.write(playbook, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        run_dep: #{run_dep}
      roles:
        - parent1
        - parent2
    YAML

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)
  status.success?.must_equal(true)
  output.to_s.gsub(/\e\[[0-9;]*m/, "")
end

private def count_lines(output : String, needle : String) : Int32
  output.lines.count(&.starts_with?(needle))
end

describe "identical meta dependency reached again: dedup decided per host at run time" do
  it "runs (skips) twice when the shared dependency's when: is false on every reach" do
    # Real: a fully-skipped earlier occurrence never counts as "ran"
    # (role._had_task_run only turns on a non-skipped result), so every
    # later reach still runs and prints its own full skipping: block.
    src_dir = File.tempname("role-runtime-dedup-false")
    write_runtime_dedup_role(src_dir, "shared")
    write_runtime_dedup_role(src_dir, "parent1")
    write_runtime_dedup_role(src_dir, "parent2")

    output = run_runtime_dedup_playbook(src_dir, "false")

    count_lines(output, "TASK [shared : shared task]").must_equal(2)
    count_lines(output, "skipping: [localhost]").must_equal(2)
    output.must_include("parent1 ran")
    output.must_include("parent2 ran")
    output.must_match(/skipped=2\b/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "runs once - later reaches silently skipped, no output at all - when the shared dependency's when: is true" do
    # Real: the first occurrence ran (non-skipped results), so the second
    # identical invocation is silently dropped: no second banner, no
    # `skipping:` line, no extra recap entry - only the two parent tasks
    # plus one shared run remain.
    src_dir = File.tempname("role-runtime-dedup-true")
    write_runtime_dedup_role(src_dir, "shared")
    write_runtime_dedup_role(src_dir, "parent1")
    write_runtime_dedup_role(src_dir, "parent2")

    output = run_runtime_dedup_playbook(src_dir, "true")

    count_lines(output, "TASK [shared : shared task]").must_equal(1)
    count_lines(output, "skipping: [localhost]").must_equal(0)
    output.must_include("shared ran")
    output.must_include("parent1 ran")
    output.must_include("parent2 ran")
    output.must_match(/ok=3\b/)
    output.must_match(/skipped=0\b/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "still runs every time when the shared dependency's own meta declares allow_duplicates: true" do
    # allow_duplicates: true in the SHARED role's own meta opts out of
    # dedup entirely - both identical invocations run, even though the
    # first one completed non-skipped tasks.
    src_dir = File.tempname("role-runtime-dedup-allow")
    write_runtime_dedup_role(src_dir, "shared", "allow_duplicates: true\n")
    write_runtime_dedup_role(src_dir, "parent1")
    write_runtime_dedup_role(src_dir, "parent2")

    output = run_runtime_dedup_playbook(src_dir, "true")

    count_lines(output, "TASK [shared : shared task]").must_equal(2)
    count_lines(output, "ok: [localhost]").must_equal(4)
    output.must_include("parent1 ran")
    output.must_include("parent2 ran")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
