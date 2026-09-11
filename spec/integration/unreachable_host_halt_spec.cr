require "file_utils"
require "digest/md5"
require "../spec_helper"

# Round 601090 (robertdebock.common, kata backend, WARM rerun): a host
# the previous run had left dead must come out of this engine exactly
# like real ansible-playbook's own warm rerun did - `fatal: ...
# UNREACHABLE!` at Gathering Facts, the host halted for the rest of the
# run (no further per-host activity, no "failed" tasks booked against
# it), recap `unreachable=1 failed=0`, exit 4.
#
# The warm-run trap this spec reproduces without any live host: the
# on-disk host-state cache (persisted by the PREVIOUS run in a
# different process) believes every plugin binary is already verified
# present, so the pre-run upload pass short-circuits without ever
# touching the network - the pre-existing "known unreachable" path
# never fires, and only the mid-run discovery introduced for this bug
# can classify the failure. 127.0.0.1:1 is used so the SSH failure is
# an instant "Connection refused", not a routing timeout.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_unreachable_repro : {Int32, String}
  dir = File.tempname("unreachable-repro")
  Dir.mkdir_p(dir)

  cache_dir = File.join(dir, "cache")
  cache_entries = {"root@127.0.0.1:1" => {"_verified_at" => Time.utc.to_unix.to_s}} of String => Hash(String, String)
  Dir.mkdir_p(File.join(cache_dir, "krikri-playbook"))
  # The cache entry must claim the exact md5s of the binaries this run
  # will require, or upload_plugins_to_host falls back to the listing
  # round trip and the PRE-run unreachable path fires instead of the
  # mid-run discovery this spec exists to pin.
  {"facts", "command"}.each do |plugin|
    path = File.join(PROJECT_ROOT, "bin", "plugins", plugin)
    raise "Plugin binary not found: #{path} (run ./build.sh first)" unless File.exists?(path)
    md5 = Digest::MD5.hexdigest(File.read(path))
    cache_entries["root@127.0.0.1:1"][plugin] = md5
  end
  File.write(File.join(cache_dir, "krikri-playbook", "plugin-state.json"),
    cache_entries.to_json)

  File.write(File.join(dir, "inv.ini"),
    "deadhost ansible_host=127.0.0.1 ansible_port=1 ansible_user=root ansible_connection=ssh\n")
  File.write(File.join(dir, "pb.yml"), <<-YAML)
    - hosts: deadhost
      gather_facts: true
      tasks:
        - name: never runs
          ansible.builtin.command: /bin/true
    YAML

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", "inv.ini", "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir,
    env: {"XDG_CACHE_HOME" => cache_dir})
  {status.exit_code, stdout_io.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "an unreachable host discovered mid-run" do
  it "books UNREACHABLE at Gathering Facts, halts the host, and recaps unreachable=1 failed=0" do
    code, output = run_unreachable_repro
    code.should eq(4)

    output.should contain(%(fatal: [deadhost]: UNREACHABLE!))
    # The host is halted: the follow-up task never reports against it
    # at all - no "failed:", no "skipping:" (real Ansible books
    # skipped=0 for a host removed at its first task), no further
    # activity of any kind.
    output.should_not contain(%(fatal: [deadhost]: FAILED!))
    output.should_not contain("skipping: [deadhost]")
    output.should_not contain(%(ok: [deadhost]))

    recap = output.lines.find(&.starts_with?("deadhost"))
    if recap.nil?
      raise "no recap line for deadhost in:\n#{output}"
    end
    recap.should contain("ok=0")
    recap.should contain("unreachable=1")
    recap.should contain("failed=0")
    recap.should contain("skipped=0")
  end
end
