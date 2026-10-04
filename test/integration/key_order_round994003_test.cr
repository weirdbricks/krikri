require "../minitest_helper"
require "file_utils"
require "json"

# round994002 (kop_misc2, Ubuntu 22.04) / round994003 (kop_rocky, Rocky
# Linux 9) registered-result shapes, captured from real ansible-core
# 2.19.11 via the probe roles' `KEYORDER|<probe>|{{ r | to_json }}`
# debug lines and pinned here against krikri:
#
# - ansible.posix.firewalld (round994003): success results carry real's
#   msg composition ("Permanent and Non-Permanent(immediate) operation[,
#   Changed <thing> <value> to <state>]") and register as
#   [changed, msg, failed]; a check-mode would-change registers as bare
#   [changed, failed]; a failure registers as
#   [failed, msg, changed, exception] with real's
#   "ERROR: Exception caught: <dbus exception> <joined msgs>" text. The
#   plugin used to emit a `zone` key real never has, msg-less failures
#   (it echoed the CLI's empty stdout while the error went to stderr),
#   and - the actual bug that failed a task real succeeds at - drove
#   firewall-cmd's nonexistent --remove-service-from-zone flag.
#
#   The firewalld specs need a writable /etc/firewalld/zones (the
#   plugin's permanent leg edits the zone XML in place), so they run the
#   full engine inside the throwaway fedora container (root there), with
#   a stateful fake firewall-cmd + python-interpreter shims on PATH (the
#   latter satisfies the plugin's firewall-library import gate). The
#   permanent+immediate combination is what the real capture used.
#
# - ansible.builtin.service (both rounds): on a systemd host real's
#   service ACTION plugin dispatches to the systemd module, whose
#   registered result is [name, changed, status, (enabled,) state,
#   failed] - status being the full `systemctl show` property dict, and
#   NO msg key. krikri used to register [changed, msg, failed]. These
#   specs run on the host against a stateful fake systemctl.
#
# - ansible.builtin.dnf (round994003): real registers
#   [msg, changed, results, rc, failed] on a dnf4 host (Rocky 9) - the
#   module's own response-dict order - while krikri emitted the dnf5
#   kwargs order. The plugin-level order is pinned in
#   test/unit/dnf_backend_key_order_test.cr; the full registered shape
#   (with the controller's failed backfill) is pinned here.

private PROJECT_ROOT        = File.expand_path("../..", __DIR__)
private BINARY              = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY           = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")
private FEDORA_COMPAT_IMAGE = "localhost/krikri-fedora-compat:latest"

# Runs a play body with `env` merged into the engine process environment
# (the plugin binaries inherit it, so PATH shims reach both the plugins'
# own probes and their remote_exec commands) and returns every
# `{{ r | to_json }}` dump the play wrote, keyed by dump name.
private def run_play_dumps(play_body : String, env : Hash(String, String), work : String) : Hash(String, JSON::Any)
  FileUtils.mkdir_p(work)
  File.write(File.join(work, "play.yml"), play_body)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, File.join(work, "play.yml")],
    output: output, error: output, env: ENV.to_h.merge(env))
  status.success?.must_equal(true, output.to_s[-2000..]? || output.to_s)
  dumps = {} of String => JSON::Any
  Dir.glob(File.join(work, "out-*.json")).each do |path|
    dumps[File.basename(path, ".json").lchop("out-")] = JSON.parse(File.read(path))
  end
  dumps
ensure
  FileUtils.rm_rf(work) if work && File.exists?(work)
end

# A dump task after every registered chunk, emitted as YAML at the
# caller's indentation. `dest_dir` is the directory the play (wherever it
# runs, host or container) can write to.
private def dump_task(label : String, dest_dir : String) : String
  "    - name: dump #{label}\n" \
  "      ansible.builtin.copy:\n" \
  "        content: \"{{ r | to_json }}\"\n" \
  "        dest: #{File.join(dest_dir, "out-#{label}.json")}\n"
end

# ---------------------------------------------------------------------------
# ansible.posix.firewalld
# ---------------------------------------------------------------------------

FW_FIREWALLD_STATEFUL_SHIM = <<-SHIM
  #!/bin/sh
  echo "$@" >> "$KRIKRI_FW_LOG"
  if [ "$1" = "--state" ]; then
    echo running
    exit 0
  fi
  if [ "$1" = "--get-default-zone" ]; then
    echo public
    exit 0
  fi
  zone=""; value=""; action=""
  for arg in "$@"; do
    case "$arg" in
      --zone=*) zone="${arg#--zone=}";;
      --list-services) action="list";;
      --query-service=*) action="query_service"; value="${arg#--query-service=}";;
      --query-*) action="query"; value="${arg#*=}";;
      --add-*) action="add"; value="${arg#*=}";;
      --remove-*) action="remove"; value="${arg#*=}";;
    esac
  done
  case "$action" in
    list)
      # real's ServiceTransaction reads the zone's whole service list
      # (`service in self.fw.getServices(zone)`) - space-separated on one line (like firewall-cmd) -
      # never --query-service, which rejects an undefined service name.
      if [ -f "$KRIKRI_FW_STATE" ]; then
        grep -F "$zone|" "$KRIKRI_FW_STATE" | cut -d'|' -f2 | tr '\n' ' '; echo
      fi
      exit 0
      ;;
    query_service)
      # Real firewall-cmd rejects --query-service=<name> for a name no
      # service XML defines: "Error: INVALID_SERVICE: <name>" on stderr,
      # exit code firewalld's INVALID_SERVICE (not 0/1) - firewalld
      # 1.2.3's firewall/command.py exception_handler. That rejection is
      # exactly what krikri's old --query-service probe tripped over on
      # the round996006 host.
      for d in /usr/lib/firewalld/services /etc/firewalld/services; do
        [ -f "$d/$value.xml" ] && found=1
      done
      if [ -z "$found" ]; then
        echo "Error: INVALID_SERVICE: $value" >&2
        exit 2
      fi
      found=""
      if [ -f "$KRIKRI_FW_STATE" ] && grep -Fxq "$zone|$value" "$KRIKRI_FW_STATE"; then
        exit 0
      fi
      exit 1
      ;;
    query)
      if [ -f "$KRIKRI_FW_STATE" ] && grep -Fxq "$zone|$value" "$KRIKRI_FW_STATE"; then
        exit 0
      fi
      exit 1
      ;;
    add)
      if [ "$value" = "kop_nosuch_svc" ]; then
        echo "Error: INVALID_SERVICE: Zone '$zone': '$value' not among existing services" >&2
        exit 1
      fi
      echo "$zone|$value" >> "$KRIKRI_FW_STATE"
      exit 0
      ;;
    remove)
      if [ -f "$KRIKRI_FW_STATE" ]; then
        grep -Fvx "$zone|$value" "$KRIKRI_FW_STATE" > "$KRIKRI_FW_STATE.tmp" || true
        mv "$KRIKRI_FW_STATE.tmp" "$KRIKRI_FW_STATE"
      fi
      exit 0
      ;;
  esac
  exit 0
  SHIM

describe "firewalld registered shapes (round994003, podman container)" do
  serial!

  it "registers real's permanent+immediate success/check/failure shapes" do
    unless PluginSpecHelper.container_cli_available?
      skip("podman unavailable")
    end
    output = IO::Memory.new
    Process.run("podman", ["image", "exists", FEDORA_COMPAT_IMAGE], output: output, error: output)
    skip("#{FEDORA_COMPAT_IMAGE} unavailable") unless $?.success?

    shims = PluginSpecHelper.tmp_path("fw994003-shims")
    FileUtils.mkdir_p(shims)
    File.write(File.join(shims, "firewall-cmd"), FW_FIREWALLD_STATEFUL_SHIM)
    # Same flags, so the permanent rich-rule leg (which drives
    # firewall-offline-cmd) hits the same fake.
    File.write(File.join(shims, "firewall-offline-cmd"), FW_FIREWALLD_STATEFUL_SHIM)
    # The firewall-library import gate probes the plugin process's own
    # PATH with real's interpreter-discovery order.
    %w[python3.13 python3.12 python3.11 python3.10 python3].each do |py_shim|
      File.write(File.join(shims, py_shim), "#!/bin/sh\nexit 0\n")
    end
    %w[firewall-cmd firewall-offline-cmd python3.13 python3.12 python3.11 python3.10 python3].each do |shim|
      File.chmod(File.join(shims, shim), 0o755)
    end

    work = PluginSpecHelper.tmp_path("fw994003-work")
    FileUtils.rm_rf(work)
    FileUtils.mkdir_p(work)
    dump_dir = File.join(work, "dumps")
    FileUtils.mkdir_p(dump_dir)

    play = <<-YAML
    ---
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - name: seed the public zone file (the permanent leg edits it in place)
          ansible.builtin.file:
            path: /etc/firewalld/zones
            state: directory
        - name: seed firewalld's service catalogue dir
          ansible.builtin.file:
            path: /usr/lib/firewalld/services
            state: directory
        - name: seed the two service definitions the play uses
          ansible.builtin.copy:
            dest: "/usr/lib/firewalld/services/{{ item }}.xml"
            content: |
              <?xml version="1.0" encoding="utf-8"?>
              <service><short>{{ item }}</short></service>
          loop:
            - http
            - https
        - name: write the public zone file
          ansible.builtin.copy:
            dest: /etc/firewalld/zones/public.xml
            content: |
              <?xml version="1.0" encoding="utf-8"?>
              <zone>
                <short>Public</short>
              </zone>
        - name: enable http service (changed)
          ansible.posix.firewalld:
            service: http
            permanent: true
            immediate: true
            state: enabled
          register: r
    #{dump_task("fw-svc-enable", "/work/dumps")}
        - name: enable http service again (ok)
          ansible.posix.firewalld:
            service: http
            permanent: true
            immediate: true
            state: enabled
          register: r
    #{dump_task("fw-svc-again", "/work/dumps")}
        - name: enable https service in check mode (changed)
          ansible.posix.firewalld:
            service: https
            permanent: true
            immediate: true
            state: enabled
          check_mode: true
          register: r
    #{dump_task("fw-svc-check", "/work/dumps")}
        - name: enable port 8789/tcp (changed)
          ansible.posix.firewalld:
            port: 8789/tcp
            zone: public
            permanent: true
            immediate: true
            state: enabled
          register: r
    #{dump_task("fw-port-enable", "/work/dumps")}
        - name: enable port 8789/tcp again (ok)
          ansible.posix.firewalld:
            port: 8789/tcp
            zone: public
            permanent: true
            immediate: true
            state: enabled
          register: r
    #{dump_task("fw-port-enable-again", "/work/dumps")}
        - name: disable port 8789/tcp (changed)
          ansible.posix.firewalld:
            port: 8789/tcp
            zone: public
            permanent: true
            immediate: true
            state: disabled
          register: r
    #{dump_task("fw-port-disable", "/work/dumps")}
        - name: enable rich rule (changed)
          ansible.posix.firewalld:
            rich_rule: 'rule family=ipv4 source address=192.0.2.10 accept'
            permanent: true
            immediate: true
            state: enabled
          register: r
    #{dump_task("fw-rich-enable", "/work/dumps")}
        - name: disable rich rule (changed)
          ansible.posix.firewalld:
            rich_rule: 'rule family=ipv4 source address=192.0.2.10 accept'
            permanent: true
            immediate: true
            state: disabled
          register: r
    #{dump_task("fw-rich-disable", "/work/dumps")}
        - name: invoke firewalld with an unknown service (failure)
          ansible.posix.firewalld:
            service: kop_nosuch_svc
            permanent: true
            immediate: true
            state: enabled
          register: r
          ignore_errors: true
    #{dump_task("fw-fail", "/work/dumps")}
        - name: read the zone file back (the bogus service must never land in it)
          ansible.builtin.slurp:
            src: /etc/firewalld/zones/public.xml
          register: zone_xml
        - name: dump the zone file
          ansible.builtin.copy:
            content: "{{ zone_xml.content | b64decode }}"
            dest: /work/dumps/out-fw-zone-xml.txt
        - name: cleanup guard - ensure http service is disabled again (changed on real)
          ansible.posix.firewalld:
            service: http
            permanent: true
            immediate: true
            state: disabled
          register: r
    #{dump_task("fw-cleanup-disable", "/work/dumps")}
    YAML

    # Rewrite the dump tasks' absolute dest into the work dir - dump_task
    # baked in its own tmp path, so point them at dump_dir by running the
    # play with cwd-independent absolute paths already set.
    File.write(File.join(work, "play.yml"), play)

    # The state/log paths are IN-CONTAINER paths (/work is the bind mount
    # of the host `work` dir) - the shim runs inside the container.
    cmd = "export KRIKRI_FW_LOG=/work/fw.log KRIKRI_FW_STATE=/work/fw.state; " \
          "/kbin/krikri-playbook -i localhost, -c local /work/play.yml"
    run_output = IO::Memory.new
    Process.run("podman", [
      "run", "--rm", "--name", "krikri-kp-fw994003",
      "-v", "#{File.dirname(BINARY)}:/kbin:ro",
      "-v", "#{work}:/work",
      "-v", "#{shims}:/shims:ro",
      "-e", "PATH=/shims:/usr/local/bin:/usr/bin:/bin",
      FEDORA_COMPAT_IMAGE,
      "sh", "-c", cmd,
    ], output: run_output, error: run_output)
    $?.success?.must_equal(true, run_output.to_s[-2000..]? || run_output.to_s)

    dumps = {} of String => JSON::Any
    Dir.glob(File.join(dump_dir, "out-*.json")).each do |path|
      dumps[File.basename(path, ".json").lchop("out-")] = JSON.parse(File.read(path))
    end

    context = "Permanent and Non-Permanent(immediate) operation"

    svc_enable = dumps["fw-svc-enable"].as_h
    svc_enable.keys.must_equal(["changed", "msg", "failed"])
    svc_enable["changed"].as_bool.must_equal(true)
    svc_enable["msg"].as_s.must_equal("#{context}, Changed service http to enabled")
    svc_enable["failed"].as_bool.must_equal(false)

    svc_again = dumps["fw-svc-again"].as_h
    svc_again.keys.must_equal(["changed", "msg", "failed"])
    svc_again["changed"].as_bool.must_equal(false)
    svc_again["msg"].as_s.must_equal(context)

    svc_check = dumps["fw-svc-check"].as_h
    # real's exit_json(changed=True) inside the transaction: no msg key.
    svc_check.keys.must_equal(["changed", "failed"])
    svc_check["changed"].as_bool.must_equal(true)

    port_enable = dumps["fw-port-enable"].as_h
    port_enable.keys.must_equal(["changed", "msg", "failed"])
    port_enable["changed"].as_bool.must_equal(true)
    port_enable["msg"].as_s.must_equal("#{context}, Changed port 8789/tcp to enabled")

    port_again = dumps["fw-port-enable-again"].as_h
    port_again.keys.must_equal(["changed", "msg", "failed"])
    port_again["changed"].as_bool.must_equal(false)
    port_again["msg"].as_s.must_equal(context)

    port_disable = dumps["fw-port-disable"].as_h
    port_disable.keys.must_equal(["changed", "msg", "failed"])
    port_disable["changed"].as_bool.must_equal(true)
    port_disable["msg"].as_s.must_equal("#{context}, Changed port 8789/tcp to disabled")

    rich_enable = dumps["fw-rich-enable"].as_h
    rich_enable.keys.must_equal(["changed", "msg", "failed"])
    rich_enable["msg"].as_s.must_equal(
      "#{context}, Changed rich_rule rule family=ipv4 source address=192.0.2.10 accept to enabled")

    rich_disable = dumps["fw-rich-disable"].as_h
    rich_disable.keys.must_equal(["changed", "msg", "failed"])
    rich_disable["msg"].as_s.must_equal(
      "#{context}, Changed rich_rule rule family=ipv4 source address=192.0.2.10 accept to disabled")

    fw_fail = dumps["fw-fail"].as_h
    fw_fail.keys.must_equal(["failed", "msg", "changed", "exception"])
    fw_fail["failed"].as_bool.must_equal(true)
    fw_fail["msg"].as_s.must_equal(
      "ERROR: Exception caught: org.fedoraproject.FirewallD1.Exception: " \
      "INVALID_SERVICE: Zone 'public': 'kop_nosuch_svc' not among existing services " \
      "#{context}, " \
      "Services are defined by port/tcp relationship and named as they are in /etc/services (on most systems)")
    fw_fail["changed"].as_bool.must_equal(false)
    fw_fail["exception"].as_s.must_equal("(traceback unavailable)")

    # The zone file must still hold only the services real would have
    # written: real's own permanent addService/update() rejects a name
    # no service XML defines (firewalld's check_config), so krikri
    # writing a <service name="kop_nosuch_svc"/> entry here is its own
    # bug, not a difference from real.
    zone_xml = File.read(File.join(dump_dir, "out-fw-zone-xml.txt"))
    zone_xml.includes?("kop_nosuch_svc").must_equal(false)
    zone_xml.includes?("<service name=\"http\"/>").must_equal(true)

    # The bug that failed this task on the real host: firewall-cmd has no
    # --remove-service-from-zone option (the offline-cmd-only quirk flag
    # leaked into the runtime path), so the disable died msg-less while
    # real reported changed.
    cleanup = dumps["fw-cleanup-disable"].as_h
    cleanup.keys.must_equal(["changed", "msg", "failed"])
    cleanup["changed"].as_bool.must_equal(true)
    cleanup["msg"].as_s.must_equal("#{context}, Changed service http to disabled")

    log = File.read(File.join(work, "fw.log"))
    log.includes?("--zone=public --remove-service=http").must_equal(true)
    log.includes?("remove-service-from-zone").must_equal(false)
  end
end

# ---------------------------------------------------------------------------
# ansible.builtin.service (systemd dispatch)
# ---------------------------------------------------------------------------

FW_SYSTEMCTL_SHIM = <<-SHIM
  #!/bin/sh
  echo "$@" >> "$KRIKRI_SVC_LOG"
  case "$1" in
    show)
      cat "$KRIKRI_SHOW_FILE"
      exit 0
      ;;
    is-enabled)
      if [ "$(cat "$KRIKRI_ENABLED_FILE" 2>/dev/null)" = "enabled" ]; then
        echo enabled
        exit 0
      fi
      echo disabled
      exit 1
      ;;
    start)
      sed -i 's/^ActiveState=.*/ActiveState=active/' "$KRIKRI_SHOW_FILE"
      exit 0
      ;;
    stop)
      sed -i 's/^ActiveState=.*/ActiveState=inactive/' "$KRIKRI_SHOW_FILE"
      exit 0
      ;;
    enable)
      echo enabled > "$KRIKRI_ENABLED_FILE"
      exit 0
      ;;
    disable)
      echo disabled > "$KRIKRI_ENABLED_FILE"
      exit 0
      ;;
  esac
  exit 0
  SHIM

# A representative slice of real's `systemctl show firewalld` output,
# in its own property order (round994003 firewalld_helper_service
# captured 240 keys; the order is what this pin is about).
FW_SHOW_INACTIVE = <<-SHOW
  Type=dbus
  ExitType=main
  Restart=no
  NotifyAccess=none
  RestartUSec=100ms
  TimeoutStartUSec=1min 30s
  MainPID=0
  BusName=org.fedoraproject.FirewallD1
  Result=success
  LoadState=loaded
  ActiveState=inactive
  FragmentPath=/usr/lib/systemd/system/firewalld.service
  CollectMode=inactive-or-dead
  SHOW

describe "service registered shapes (round994002/994003 systemd dispatch)" do
  serial!

  # Fresh stateful systemctl shim + show/enabled state files per call.
  private def with_svc_shims(active_state : String, enabled_state : String, &)
    shims = PluginSpecHelper.tmp_path("svc994-shims-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(shims)
    File.write(File.join(shims, "systemctl"), FW_SYSTEMCTL_SHIM)
    File.chmod(File.join(shims, "systemctl"), 0o755)
    show_file = File.join(shims, "show.txt")
    enabled_file = File.join(shims, "enabled.txt")
    File.write(show_file, FW_SHOW_INACTIVE.gsub("ActiveState=inactive", "ActiveState=#{active_state}"))
    File.write(enabled_file, enabled_state)
    env = {
      "PATH"                => "#{shims}:/usr/bin:/bin",
      "KRIKRI_SHOW_FILE"    => show_file,
      "KRIKRI_ENABLED_FILE" => enabled_file,
      "KRIKRI_SVC_LOG"      => File.join(shims, "svc.log"),
    }
    yield env
  ensure
    FileUtils.rm_rf(shims) if shims
  end

  it "registers name/changed/status/enabled/state with the full status dict (no msg)" do
    with_svc_shims("inactive", "disabled") do |env|
      work = PluginSpecHelper.tmp_path("svc994-work-cold")
      FileUtils.rm_rf(work)
      dumps = run_play_dumps(<<-YAML, env, work)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        vars:
          ansible_service_mgr: systemd
        tasks:
          - name: start and enable firewalld (changed)
            ansible.builtin.service:
              name: firewalld
              state: started
              enabled: true
            register: r
      #{dump_task("svc-cold", work)}
      YAML

      cold = dumps["svc-cold"].as_h
      # real's systemd-module registered shape: [name, changed, status,
      # enabled, state, failed] - no msg key (the round994003
      # firewalld_helper_service capture).
      cold.keys.must_equal(["name", "changed", "status", "enabled", "state", "failed"])
      cold["name"].as_s.must_equal("firewalld")
      cold["changed"].as_bool.must_equal(true)
      cold["enabled"].as_bool.must_equal(true)
      cold["state"].as_s.must_equal("started")
      cold["failed"].as_bool.must_equal(false)
      status = cold["status"].as_h
      status.keys.must_equal([
        "Type", "ExitType", "Restart", "NotifyAccess", "RestartUSec",
        "TimeoutStartUSec", "MainPID", "BusName", "Result", "LoadState",
        "ActiveState", "FragmentPath", "CollectMode",
      ])
      # The status dict is the PRE-action `systemctl show` snapshot, same
      # as real's (it never re-reads after the mutations).
      status["ActiveState"].as_s.must_equal("inactive")
      status["LoadState"].as_s.must_equal("loaded")
    end
  end

  it "registers the same shape unchanged on a warm rerun" do
    with_svc_shims("active", "enabled") do |env|
      work = PluginSpecHelper.tmp_path("svc994-work-warm")
      FileUtils.rm_rf(work)
      dumps = run_play_dumps(<<-YAML, env, work)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        vars:
          ansible_service_mgr: systemd
        tasks:
          - name: start and enable firewalld again (ok)
            ansible.builtin.service:
              name: firewalld
              state: started
              enabled: true
            register: r
      #{dump_task("svc-warm", work)}
      YAML

      warm = dumps["svc-warm"].as_h
      warm.keys.must_equal(["name", "changed", "status", "enabled", "state", "failed"])
      warm["changed"].as_bool.must_equal(false)
      warm["enabled"].as_bool.must_equal(true)
      warm["state"].as_s.must_equal("started")
    end
  end

  # round994002 virt_net_helper_service: no enabled: param - the enabled
  # key is absent entirely.
  it "omits the enabled key when no enabled: param was given" do
    with_svc_shims("active", "enabled") do |env|
      work = PluginSpecHelper.tmp_path("svc994-work-noenable")
      FileUtils.rm_rf(work)
      dumps = run_play_dumps(<<-YAML, env, work)
      ---
      - hosts: localhost
        gather_facts: false
        connection: local
        vars:
          ansible_service_mgr: systemd
        tasks:
          - name: ensure the service is started (ok, no enabled param)
            ansible.builtin.service:
              name: firewalld
              state: started
            register: r
      #{dump_task("svc-noenable", work)}
      YAML

      noenable = dumps["svc-noenable"].as_h
      noenable.keys.must_equal(["name", "changed", "status", "state", "failed"])
      noenable["changed"].as_bool.must_equal(false)
      noenable["state"].as_s.must_equal("started")
    end
  end
end

# ---------------------------------------------------------------------------
# ansible.builtin.dnf (full registered shape, dnf4 backend)
# ---------------------------------------------------------------------------

describe "dnf registered shape (round994003 dnf4 backend)" do
  serial!

  it "registers msg, changed, results, rc, failed on a dnf4 host" do
    skip "host has /usr/bin/dnf or /usr/bin/microdnf - the backend probe would resolve them" if File.exists?("/usr/bin/dnf") || File.exists?("/usr/bin/microdnf")

    shim_dir = PluginSpecHelper.tmp_path("dnf994-shim")
    FileUtils.mkdir_p(shim_dir)
    File.write("#{shim_dir}/dnf", "#!/bin/sh\ncat <<'KRIKRI_FAKE_DNF_EOF'\nDependencies resolved.\n================================================================================\n Transaction Summary\n================================================================================\n\nComplete!\nKRIKRI_FAKE_DNF_EOF\n")
    File.chmod("#{shim_dir}/dnf", 0o755)

    work = PluginSpecHelper.tmp_path("dnf994-work")
    FileUtils.rm_rf(work)
    dumps = run_play_dumps(<<-YAML, {"PATH" => "#{shim_dir}:/usr/bin:/bin"}, work)
    ---
    - hosts: localhost
      gather_facts: false
      connection: local
      tasks:
        - name: dnf group no-op (real Rocky capture shape)
          ansible.builtin.dnf:
            name: "@Development tools"
            state: present
          register: r
    #{dump_task("dnf-noop", work)}
    YAML

    noop = dumps["dnf-noop"].as_h
    noop.keys.must_equal(["msg", "changed", "results", "rc", "failed"])
    noop["msg"].as_s.must_equal("Nothing to do")
    noop["changed"].as_bool.must_equal(false)
    noop["results"].as_a.must_equal([] of JSON::Any)
    noop["rc"].as_i.must_equal(0)
    noop["failed"].as_bool.must_equal(false)
  end
end
