require "../minitest_helper"
require "file_utils"

# The looped include_role: whose role name does not resolve - real
# ansible-core 2.19.11 (live-verified, minimal repro) prints NO fatal:
# line per failing item on stdout, only one "[ERROR]: the role 'x' was
# not found in <search paths>" block per item on STDERR, whose Origin
# points at that loop ITEM's own YAML position (not the name: value);
# the recap still counts failed=1 per item and every item is attempted.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "looped include_role: with an unresolvable role name" do
  it "prints only stderr [ERROR] blocks with per-item Origins, no fatal lines, failed=2" do
    src_dir = File.tempname("include-role-missing-loop")
    Dir.mkdir_p(src_dir)

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: include missing roles
            include_role:
              name: "{{ item }}"
            loop:
              - stafwag.libvirt
              - stafwag.also_missing
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr, chdir: src_dir, input: IO::Memory.new)
    out = stdout.to_s
    err = stderr.to_s

    # No fatal: result line per item - only the [ERROR] block, per item.
    out.each_line.none?(&.starts_with?("fatal:")).must_equal(true)
    out.wont_include("FAILED!")

    err.must_include("[ERROR]: the role 'stafwag.libvirt' was not found in ")
    err.must_include("[ERROR]: the role 'stafwag.also_missing' was not found in ")
    # Both items' Origins point at their own YAML line (column 11 = the
    # scalar after the 8-space indent + "- "), not at the name: value.
    err.must_include("Origin: #{playbook}:10:11\n")
    err.must_include("Origin: #{playbook}:11:11\n")

    # Every item is attempted and counted: failed=2 in the recap, and
    # the play halts for the host (rc=2).
    out.must_match(/ok=0\s+changed=0\s+unreachable=0\s+failed=2\s+skipped=0\s+rescued=0\s+ignored=0/)
    status.exit_code.must_equal(2)

    FileUtils.rm_rf(src_dir)
  end

  it "keeps the fatal line and the name-value Origin for a non-loop include_role" do
    # Guard for the loop-only change: the single (non-loop) role-not-found
    # shape - one fatal: line per host on stdout with the name-value
    # Origin on stderr - must be untouched.
    src_dir = File.tempname("include-role-missing-single")
    Dir.mkdir_p(src_dir)

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: include missing role
            include_role:
              name: stafwag.nope
      YAML

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: stdout, error: stderr, chdir: src_dir, input: IO::Memory.new)
    out = stdout.to_s
    err = stderr.to_s

    out.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"reason\": \"the role 'stafwag.nope' was not found in ")
    err.must_include("Origin: #{playbook}:8:15\n")
    out.must_match(/ok=0\s+changed=0\s+unreachable=0\s+failed=1\s+skipped=0\s+rescued=0\s+ignored=0/)
    status.exit_code.must_equal(2)

    FileUtils.rm_rf(src_dir)
  end
end
