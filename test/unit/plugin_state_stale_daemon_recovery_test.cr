require "../minitest_helper"
require "file_utils"
require "../../src/krikri/plugin_manager"

private PROJECT_ROOT_1158 = File.expand_path("../..", __DIR__)
private BINARY_1158       = File.join(PROJECT_ROOT_1158, "bin", "krikri-playbook")

# Issue #1158 - the run-to-run facet of #1109: a /var/tmp sweep on the
# TARGET wipes the staged plugin cache while the controller-side
# plugin-state record of the previous run's verification survives, and
# the next run was ~2x slower on a real host (39.6s vs 24.0s warm,
# 54 one-shot ssh execs and ZERO daemon requests where a warm run had
# 11 daemon requests): the daemon spawn handshake failed against the
# very binary that was missing, spawn_daemon stamped the connection
# permanently daemon-less, and even after the missing-binary recovery
# re-uploaded the binary the run stayed on the per-task ssh path.
#
# End-to-end against the BUILT binary with a stub ssh/rsync/scp on PATH
# that runs every "remote" command on the local filesystem instead of
# dialing out - the whole scenario (record kept, staging dir wiped in
# between runs) is then reproducible with no real host, and the
# transport choice is read off the run's own --timing-profile block,
# exactly the observable the issue was filed against. Both dispatch
# shapes are covered: batch groups (whole plays at a time) and the solo
# path (run_once: tasks, whose groups are too small to batch).
#
# The staging dir is keyed on the inventory USER (a per-test random
# one), so the wipe can never touch another test's staged plugins.

private STUB_SSH = <<-BASH
  #!/bin/bash
  # krikri test stub: BE the remote side - strip ssh's own argv up to
  # the user@host target and run the remote command locally.
  target_seen=0
  remote=()
  for a in "$@"; do
    if [ "$target_seen" -eq 1 ]; then
      remote+=("$a")
      continue
    fi
    if [[ "$a" =~ ^[A-Za-z0-9_.:-]+@[A-Za-z0-9_.-]+$ ]]; then
      target_seen=1
    fi
  done
  if [ "$target_seen" -eq 0 ]; then
    echo "ssh stub: no user@host target in argv: $*" >&2
    exit 255
  fi
  exec /bin/bash -c "${remote[*]}"
  BASH

private STUB_RSYNC = <<-BASH
  #!/bin/bash
  # krikri test stub: copy the batch locally instead of an ssh rsync.
  positional=()
  skip=0
  for a in "$@"; do
    if [ "$skip" -eq 1 ]; then
      skip=0
      continue
    fi
    case "$a" in
      -e) skip=1 ;;
      -*) ;;
      *) positional+=("$a") ;;
    esac
  done
  if [ "${#positional[@]}" -lt 2 ]; then
    echo "rsync stub: expected sources and a user@host:dir destination" >&2
    exit 1
  fi
  dest="${positional[${#positional[@]}-1]}"
  unset 'positional[${#positional[@]}-1]'
  dir="${dest#*:}"
  mkdir -p "$dir" || exit 1
  for f in "${positional[@]}"; do
    cp -f "$f" "$dir/" || exit 1
  done
  exit 0
  BASH

private STUB_SCP = <<-BASH
  #!/bin/bash
  # krikri test stub: the scp fallback of the same upload path.
  positional=()
  skip=0
  for a in "$@"; do
    if [ "$skip" -eq 1 ]; then
      skip=0
      continue
    fi
    case "$a" in
      -o|-P|-i|-F) skip=1 ;;
      -*) ;;
      *) positional+=("$a") ;;
    esac
  done
  if [ "${#positional[@]}" -lt 2 ]; then
    echo "scp stub: expected a source and a user@host:path destination" >&2
    exit 1
  fi
  dest="${positional[${#positional[@]}-1]}"
  unset 'positional[${#positional[@]}-1]'
  src="${positional[${#positional[@]}-1]}"
  path="${dest#*:}"
  mkdir -p "$(dirname "$path")" || exit 1
  cp -f "$src" "$path" || exit 1
  exit 0
  BASH

private def install_stubs(dir : String) : Nil
  Dir.mkdir_p(dir)
  {"ssh" => STUB_SSH, "rsync" => STUB_RSYNC, "scp" => STUB_SCP}.each do |name, body|
    path = File.join(dir, name)
    File.write(path, body)
    File.chmod(path, 0o755)
  end
end

private def run_1158(inventory : String, playbook : String, stubs : String, cache : String) : String
  out_io = IO::Memory.new
  err_io = IO::Memory.new
  Process.run(BINARY_1158, ["-i", inventory, playbook, "--timing-profile"],
    env: {
      "PATH"           => "#{stubs}:/usr/bin:/bin",
      "HOME"           => cache,
      "XDG_CACHE_HOME" => cache,
    },
    clear_env: true,
    output: out_io,
    error: err_io)
  out_io.to_s
end

private def recap_1158(output : String) : String
  output.lines.reverse!.find!(&.includes?("ok="))
end

# The count of one --timing-profile transport row (0 when the row is
# absent, i.e. the transport was never used).
private def timing_count(output : String, label : String) : Int32
  output.each_line do |line|
    if md = line.match(/^\s+#{Regex.escape(label)}\s+(\d+)\s/)
      return md[1].to_i
    end
  end
  0
end

private def assert_stays_on_daemon(output : String, max_execs : Int32) : Nil
  daemon = timing_count(output, "daemon request (pipe round trip)") +
           timing_count(output, "daemon batch request (pipe round trip)")
  execs = timing_count(output, "ssh exec_script (batched / one-shot)")
  # Before the fix the failed daemon handshake stamped the connection
  # daemon-less for the whole run: 0 daemon requests and one one-shot
  # ssh exec per task/batch-group (plus the recovery's own round trips)
  # - the ~2x slowdown of the issue. Now the run costs the warm shape:
  # one failed spawn, the recovery's round trips, and the daemon.
  (daemon >= 1).must_equal(true, "expected the run to continue on the daemon path, timing profile shows #{daemon} daemon request(s): #{output}")
  (execs <= max_execs).must_equal(true, "expected per-task ssh to stay at the recovery floor, timing profile shows #{execs} exec_script call(s): #{output}")
end

describe "a stale plugin-state record keeps the daemon path (issue #1158)" do
  it "batched groups ride the daemon again after the target's plugin cache is wiped" do
    skip "bin/krikri-playbook and plugin binaries not built (run ./build.sh first)" unless File.exists?(BINARY_1158) && File.exists?(File.join(PluginSpecHelper::PLUGINS_DIR, "command"))

    root = PluginSpecHelper.tmp_path("stale-plugin-state-batch")
    FileUtils.rm_rf(root)
    Dir.mkdir_p(root)
    stubs = File.join(root, "stubs")
    install_stubs(stubs)
    cache = File.join(root, "cache")
    Dir.mkdir_p(cache)

    # A unique inventory user gives the run its own target-side staging
    # dir (/var/tmp/.krikri-playbook-<user tag>), so the wipe below can
    # never touch another test's staged plugins.
    user = "k1158a#{Random::Secure.hex(4)}"
    staging = "/var/tmp/.krikri-playbook-#{Krikri::PluginManager.staging_dir_tag(user)}"
    inventory = File.join(root, "inventory.ini")
    File.write(inventory, "[targets]\nstubhost ansible_user=#{user}\n")
    playbook = File.join(root, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: all
        gather_facts: false
        tasks:
          - name: p1 echo alpha
            command: echo alpha
          - name: p1 marker dir
            file: path=#{root}/marker state=directory
      - hosts: all
        gather_facts: false
        tasks:
          - name: p2 echo beta
            command: echo beta
          - name: p2 marker stat
            stat: path=#{root}/marker
      - hosts: all
        gather_facts: false
        tasks:
          - name: p3 echo gamma
            command: echo gamma
          - name: p3 echo delta
            command: echo delta
      YAML

    begin
      warm = run_1158(inventory, playbook, stubs, cache)
      recap_1158(warm).must_include("ok=6")
      recap_1158(warm).must_include("failed=0")

      # The issue's exact scenario: the TARGET's plugin cache is wiped
      # while the controller-side record of the previous verification
      # survives (it lives under the run's XDG_CACHE_HOME, untouched).
      FileUtils.rm_rf(staging)
      Dir.exists?(staging).must_equal(false)

      rerun = run_1158(inventory, playbook, stubs, cache)
      recap_1158(rerun).must_include("ok=6")
      recap_1158(rerun).must_include("failed=0")
      recap_1158(rerun).must_include("unreachable=0")

      # 3 play-sized batch groups: before the fix each paid a halted
      # script plus the recovery's list/write round trips plus a re-send
      # script (12 execs, no daemon); now only the FIRST group pays the
      # recovery and all three ride the daemon (3 execs: the halted
      # script and the recovery's two).
      assert_stays_on_daemon(rerun, 4)
    ensure
      FileUtils.rm_rf(staging)
    end
  end

  it "solo tasks ride the daemon again after the target's plugin cache is wiped" do
    skip "bin/krikri-playbook and plugin binaries not built (run ./build.sh first)" unless File.exists?(BINARY_1158) && File.exists?(File.join(PluginSpecHelper::PLUGINS_DIR, "command"))

    root = PluginSpecHelper.tmp_path("stale-plugin-state-solo")
    FileUtils.rm_rf(root)
    Dir.mkdir_p(root)
    stubs = File.join(root, "stubs")
    install_stubs(stubs)
    cache = File.join(root, "cache")
    Dir.mkdir_p(cache)

    user = "k1158b#{Random::Secure.hex(4)}"
    staging = "/var/tmp/.krikri-playbook-#{Krikri::PluginManager.staging_dir_tag(user)}"
    inventory = File.join(root, "inventory.ini")
    File.write(inventory, "[targets]\nstubhost ansible_user=#{user}\n")
    playbook = File.join(root, "site.yml")
    # run_once: breaks the batch run around every task, so each is its
    # own group of one - too small to batch (TaskBatcher.plan), i.e.
    # the solo execute_remote_plugin_transport path the post-recovery
    # daemon retry lives on.
    File.write(playbook, <<-YAML)
      ---
      - hosts: all
        gather_facts: false
        tasks:
          - name: solo echo one
            command: echo one
            run_once: true
          - name: solo marker dir
            file: path=#{root}/solo-marker state=directory
            run_once: true
          - name: solo echo two
            command: echo two
            run_once: true
      YAML

    begin
      warm = run_1158(inventory, playbook, stubs, cache)
      recap_1158(warm).must_include("ok=3")
      recap_1158(warm).must_include("failed=0")

      FileUtils.rm_rf(staging)
      Dir.exists?(staging).must_equal(false)

      rerun = run_1158(inventory, playbook, stubs, cache)
      recap_1158(rerun).must_include("ok=3")
      recap_1158(rerun).must_include("failed=0")
      recap_1158(rerun).must_include("unreachable=0")

      # 3 solo dispatches: before the fix the first failed its spawn,
      # recovered, re-ran over one-shot ssh and stamped the connection
      # daemon-less - and the NEXT solo task hit the same wall again
      # (its own module name was still missing), 9 execs and no daemon.
      # Now the first task's recovery re-stages and continues on the
      # daemon, which serves the rest (3 execs: the failed one-shot and
      # the recovery's two).
      assert_stays_on_daemon(rerun, 4)
    ensure
      FileUtils.rm_rf(staging)
    end
  end
end
