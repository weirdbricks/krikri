require "../minitest_helper"
require "file_utils"
require "json"

# round994003 kop_rocky firewalld divergences, runtime (immediate) path:
#
# - every krikri firewalld FAILURE on the real host carried NO msg at all
#   (`fatal: {"changed": false, "zone": "public"}`) because the plugin
#   echoed the CLI tool's empty stdout as the msg while the actual error
#   text goes to stderr, and because the result carried a `zone` key real
#   never emits. Real wraps the error in
#   "ERROR: Exception caught: <dbus exception> <joined context msgs>"
#   (module_utils/firewalld.py's action_handler).
# - success results need real's msg composition ("Permanent and
#   Non-Permanent(immediate) operation[, Changed <thing> <value> to
#   <state>]") instead of an empty msg, and check-mode changes register
#   as bare {changed, failed} with no msg key.
#
# These specs drive the compiled plugin against a stateful fake
# `firewall-cmd` on PATH (via the `_environment` seam) and a fake python
# interpreter that satisfies the plugin's firewall-library import gate -
# the dev machine has no firewalld bindings, so without the shim every
# probe would stop at real's missing_required_lib failure. The fake CLI
# implements only the runtime context, so these specs run with
# `permanent: false` (context msg "Non-permanent operation"); the full
# permanent+immediate shapes captured on the real Rocky host are pinned
# in test/integration/key_order_round994003_test.cr (podman container,
# where the on-disk zone XML is writable).

private def with_fake_firewall_cmd(&)
  dir = PluginSpecHelper.tmp_path("fake-fw-cmd-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  log = File.join(dir, "calls.log")
  state = File.join(dir, "state")

  File.write(File.join(dir, "firewall-cmd"), <<-'SHIM')
    #!/bin/sh
    echo "$@" >> "$KRIKRI_FW_LOG"
    if [ "$1" = "--state" ]; then
      echo running
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
        # (`service in self.fw.getServices(zone)`), space-separated on one line (like firewall-cmd) -
        # NOT a --query-service probe, which rejects an undefined name.
        if [ -f "$KRIKRI_FW_STATE" ]; then
          grep -F "$zone|" "$KRIKRI_FW_STATE" | cut -d'|' -f2 | tr '\n' ' '; echo
        fi
        exit 0
        ;;
      query_service)
        # Real firewall-cmd REJECTS --query-service=<name> for a name no
        # service XML defines: "Error: INVALID_SERVICE: <name>" on
        # stderr with firewalld's own INVALID_SERVICE exit code (not
        # 0/1). Reproduced from firewalld 1.2.3's
        # firewall/command.py exception_handler - this is what made
        # krikri's old --query-service probe fail early on the round996006
        # host instead of reporting real's zone-context error.
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

  # The firewall-library import gate probes the plugin process's own
  # PATH (Process.find_executable, not a remote_exec command), so the
  # python shims ride in the same dir and the env: child PATH.
  %w[python3.13 python3.12 python3 python].each do |py_shim|
    File.write(File.join(dir, py_shim), "#!/bin/sh\nexit 0\n")
  end

  %w[firewall-cmd python3.13 python3.12 python3 python].each do |shim|
    File.chmod(File.join(dir, shim), 0o755)
  end

  path = "#{dir}:#{ENV["PATH"]}"
  env = {
    "PATH"            => path,
    "KRIKRI_FW_LOG"   => log,
    "KRIKRI_FW_STATE" => state,
  }
  yield env, log, state
ensure
  FileUtils.rm_rf(dir) if dir
end

# Runs one firewalld task against the fake CLI. `permanent: false` keeps
# the plugin on the runtime-only path (the fake CLI's only context).
private def run_fw(env : Hash(String, String), params : Hash(String, String)) : JSON::Any
  PluginSpecHelper.run("firewalld", params.merge({
    "permanent"    => "false",
    "immediate"    => "true",
    "_environment" => env.to_json,
  }), env: {"PATH" => env["PATH"]})
end

describe "firewalld plugin - round994003 runtime shapes (fake firewall-cmd)" do
  it "registers a fresh enable with real's msg composition and key order" do
    with_fake_firewall_cmd do |env, _log, _state|
      result = run_fw(env, {"zone" => "public", "service" => "http", "state" => "enabled"})

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal(
        "Non-permanent operation, Changed service http to enabled")
      # Plugin-level keys; the controller appends `failed: false` last,
      # so the registered shape is [changed, msg, failed] - exactly the
      # round994003 firewalld_service_enable capture. Real never emits a
      # `zone` key.
      result.as_h.keys.must_equal(["changed", "msg"])
    end
  end

  it "registers an idempotent rerun with the bare context msg" do
    with_fake_firewall_cmd do |env, _log, state|
      File.write(state, "public|http\n")
      result = run_fw(env, {"zone" => "public", "service" => "http", "state" => "enabled"})

      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Non-permanent operation")
      result.as_h.keys.must_equal(["changed", "msg"])
    end
  end

  it "registers a check-mode would-change as bare {changed} with no msg key" do
    with_fake_firewall_cmd do |env, _log, _state|
      result = run_fw(env, {"zone" => "public", "service" => "https", "state" => "enabled",
                            "_ansible_check_mode" => "true"})

      result["changed"].as_bool.must_equal(true)
      # real's exit_json(changed=True) inside the transaction - no msg,
      # no zone (registered shape: [changed, failed]).
      result.as_h.keys.must_equal(["changed"])
    end
  end

  it "reports an unknown service with real's ERROR: Exception caught msg and no zone key" do
    with_fake_firewall_cmd do |env, _log, _state|
      result = run_fw(env, {"zone" => "public", "service" => "kop_nosuch_svc", "state" => "enabled"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal(
        "ERROR: Exception caught: org.fedoraproject.FirewallD1.Exception: " \
        "INVALID_SERVICE: Zone 'public': 'kop_nosuch_svc' not among existing services " \
        "Non-permanent operation, " \
        "Services are defined by port/tcp relationship and named as they are in /etc/services (on most systems)")
      # real's fail_json shape (registered: [failed, msg, changed,
      # exception]) - and no `zone` key, which the plugin used to add.
      result.as_h.keys.must_equal(["failed", "msg", "changed", "exception"])
      result["exception"].as_s.must_equal("(traceback unavailable)")
    end
  end

  it "drives --remove-service (not the offline-only --remove-service-from-zone) on firewall-cmd" do
    with_fake_firewall_cmd do |env, log, state|
      File.write(state, "public|http\n")
      result = run_fw(env, {"zone" => "public", "service" => "http", "state" => "disabled"})

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal(
        "Non-permanent operation, Changed service http to disabled")
      calls = File.read(log)
      # the shim logs post-shell-quoting argv, so the value arrives unquoted
      calls.includes?("--zone=public --remove-service=http").must_equal(true)
      calls.includes?("remove-service-from-zone").must_equal(false)
    end
  end

  it "reads the zone's service LIST to probe a service, like real's getServices membership test" do
    # Real's ServiceTransaction.get_enabled_immediate is
    # `service in self.fw.getServices(self.zone)` - the whole zone list,
    # never `--query-service=<name>`. That is observable in krikri too:
    # firewall-cmd's --query-service REJECTS a name that is not a
    # defined service ("Error: INVALID_SERVICE: <name>", no zone
    # context), so probing with it made an unknown service fail before
    # real's transaction ever appends its context msg - the round996006
    # firewalld_fail divergence, where real registered
    # INVALID_SERVICE: Zone 'public': 'kop_nosuch_svc' not among
    # existing services.
    with_fake_firewall_cmd do |env, log, state|
      File.write(state, "public|http\n")
      run_fw(env, {"zone" => "public", "service" => "https", "state" => "enabled"})

      calls = File.read(log)
      calls.includes?("--zone=public --list-services").must_equal(true)
      calls.includes?("--query-service").must_equal(false)
    end
  end

  it "composes the port detail msg the same way" do
    with_fake_firewall_cmd do |env, _log, _state|
      result = run_fw(env, {"zone" => "public", "port" => "8789/tcp", "state" => "enabled"})

      result["msg"].as_s.must_equal(
        "Non-permanent operation, Changed port 8789/tcp to enabled")
    end
  end
end
