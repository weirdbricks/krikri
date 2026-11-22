require "../minitest_helper"
require "file_utils"
require "digest/md5"

# Issue #1697: a task whose first remote operation fails at the SSH
# transport reported the FALLBACK dial's mux message
# ("Shared connection to <host> closed.") instead of ssh's own failure
# ("ssh: connect to host ...: Connection refused"). Ansible's unreachable
# msg embeds the failing dial's stderr, so only the detail diverged - the
# class (UNREACHABLE) and exit code (4) already matched.
#
# Real ssh is what produces the masking: a dial that fails at connect
# leaves its control socket behind for the next dial, whose mux client
# then answers "Shared connection ... closed." instead of dialing. That
# is reproduced here with a stub `ansible_ssh_executable` (no sshd, no
# network): the invocation shape that fails FIRST prints the real connect
# error, the ones after it the mux notice. Both masking layers are
# covered because they are two separate first dials:
#
# - cold: the plugin-staging listing (`bash -s`) is the first dial, and
#   the upload's rsync/scp retries used to supply the masked text.
# - warm: a plugin-state record makes the resident daemon's spawn the
#   first dial; its stderr used to be closed, so the one-shot fallback's
#   mux notice stood in for the real error.
private TRANSPORT_DETAIL_PROJECT_ROOT = File.expand_path("../..", __DIR__)
private TRANSPORT_DETAIL_BINARY       = File.join(TRANSPORT_DETAIL_PROJECT_ROOT, "bin", "krikri-playbook")
private TRANSPORT_DETAIL_PLUGIN       = File.join(TRANSPORT_DETAIL_PROJECT_ROOT, "bin", "plugins", "shell")
private TRANSPORT_DETAIL_HOST         = "192.0.2.1"
private TRANSPORT_DETAIL_ERROR        = "ssh: connect to host #{TRANSPORT_DETAIL_HOST} port 22: Connection refused"
private TRANSPORT_DETAIL_MUX          = "Shared connection to #{TRANSPORT_DETAIL_HOST} closed."

# The transfer stubs plus an ssh stub: `--daemon` spawns answer
# *daemon_stderr*, the staging listing (`bash -s`) answers
# *list_stderr*, and everything else (rsync's/scp's child ssh) answers
# the mux notice a dead master leaves behind. Returns the ssh stub path.
private def transport_detail_stubs(dir : String, daemon_stderr : String, list_stderr : String) : String
  ssh = File.join(dir, "ssh-stub")
  File.write(ssh, <<-SH)
    #!/bin/sh
    case "$*" in
      *--daemon*) echo "#{daemon_stderr}" >&2; exit 255 ;;
      *"bash -s"*) echo "#{list_stderr}" >&2; exit 255 ;;
      *) echo "#{TRANSPORT_DETAIL_MUX}" >&2; exit 255 ;;
    esac
    SH
  File.chmod(ssh, 0o755)
  {"rsync", "scp"}.each do |name|
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\necho \"#{TRANSPORT_DETAIL_MUX}\" >&2\nexit 255\n")
    File.chmod(path, 0o755)
  end
  ssh
end

private def transport_detail_case(dir : String, ssh : String) : Nil
  File.write(File.join(dir, "inventory.ini"), <<-INI)
    local ansible_connection=local
    target ansible_connection=ssh ansible_host=#{TRANSPORT_DETAIL_HOST} ansible_user=root ansible_ssh_executable=#{ssh} ansible_ssh_common_args='-o ConnectTimeout=1'
    INI
  File.write(File.join(dir, "playbook.yml"), <<-YAML)
    - hosts: local
      gather_facts: false
      tasks:
        - raw: echo hi
          delegate_to: target
    YAML
end

private def run_transport_detail_case(dir : String, stubs : String, cache : String) : {String, Int32}
  output = IO::Memory.new
  status = Process.run(TRANSPORT_DETAIL_BINARY, ["-i", "inventory.ini", "playbook.yml"],
    output: output, error: output, chdir: dir,
    env: {
      "PATH"               => "#{stubs}:/usr/bin:/bin",
      "HOME"               => File.join(dir, "home"),
      "XDG_CACHE_HOME"     => cache,
      "ANSIBLE_NOCOLOR"    => "1",
      "ANSIBLE_PIPELINING" => "False",
    },
    clear_env: true)
  {output.to_s, status.exit_code}
end

private def assert_transport_detail(text : String, exit_code : Int32) : Nil
  text.includes?(TRANSPORT_DETAIL_ERROR).must_equal(true, text)
  text.includes?(TRANSPORT_DETAIL_MUX).must_equal(false, text)
  text.includes?("UNREACHABLE! =>").must_equal(true, text)
  exit_code.must_equal(4, text)
end

describe "ssh transport failure detail (issue #1697)" do
  it "reports the staging dial's ssh error, not the upload retries' mux close notice" do
    skip "bin/krikri-playbook and plugin binaries not built (run ./build.sh first)" unless File.exists?(TRANSPORT_DETAIL_BINARY) && File.exists?(TRANSPORT_DETAIL_PLUGIN)
    dir = PluginSpecHelper.tmp_path("transport-detail-cold")
    FileUtils.rm_rf(dir)
    Dir.mkdir_p(File.join(dir, "home"))
    ssh = transport_detail_stubs(dir, TRANSPORT_DETAIL_ERROR, TRANSPORT_DETAIL_ERROR)
    transport_detail_case(dir, ssh)

    text, exit_code = run_transport_detail_case(dir, dir, File.join(dir, "cache"))
    assert_transport_detail(text, exit_code)
  end

  it "reports the daemon spawn's ssh error, not the one-shot fallback's mux close notice" do
    skip "bin/krikri-playbook and plugin binaries not built (run ./build.sh first)" unless File.exists?(TRANSPORT_DETAIL_BINARY) && File.exists?(TRANSPORT_DETAIL_PLUGIN)
    dir = PluginSpecHelper.tmp_path("transport-detail-warm")
    FileUtils.rm_rf(dir)
    Dir.mkdir_p(File.join(dir, "home"))
    # The listing answers the mux notice: on the warm path it must never
    # run at all - a plugin-state record for this host says the binary is
    # already staged, which is what makes the daemon's spawn the first
    # dial.
    ssh = transport_detail_stubs(dir, TRANSPORT_DETAIL_ERROR, TRANSPORT_DETAIL_MUX)
    transport_detail_case(dir, ssh)

    cache = File.join(dir, "cache")
    Dir.mkdir_p(File.join(cache, "krikri-playbook"))
    state = {
      "root@#{TRANSPORT_DETAIL_HOST}:" => {
        "shell"        => Digest::MD5.new.file(TRANSPORT_DETAIL_PLUGIN).hexfinal,
        "_verified_at" => Time.utc.to_unix.to_s,
      },
    }
    File.write(File.join(cache, "krikri-playbook", "plugin-state.json"), state.to_json)

    text, exit_code = run_transport_detail_case(dir, dir, cache)
    assert_transport_detail(text, exit_code)
  end
end
