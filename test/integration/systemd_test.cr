require "../minitest_helper"
require "file_utils"

# Every check-mode prediction in the specs below is a decision made from
# what the host's own `systemctl` answers: `show <unit>` for the unit's
# properties and ActiveState, `is-enabled` for its boot state. On a host
# with no service manager at all - a plain container, e.g. the GitHub CI
# image, where `systemctl` is missing or answers "Failed to connect to
# system scope bus" - those probes yield no ActiveState, and the module
# correctly reports "Service is in unknown state" (Ansible does the
# same there). The specs are not about that failure path, so they get a
# fake `systemctl` answering exactly like a healthy systemd host whose
# only units are the not-found ones they ask about: identical on every
# machine, and nothing outside the plugin's own child process is touched.
private def systemd_run(params : Hash(String, String)) : JSON::Any
  bin_dir = PluginSpecHelper.tmp_path("fake-systemctl-query-bin")
  FileUtils.mkdir_p(bin_dir)
  fake = File.join(bin_dir, "systemctl")
  File.write(fake, <<-SH)
    #!/bin/sh
    # Skip any leading flags (--user/--global/--no-block/--force) and take
    # the verb plus the unit name that follow.
    verb=""
    unit=""
    for arg in "$@"; do
      case "$arg" in
        -*) continue;;
      esac
      if [ -z "$verb" ]; then verb="$arg"; else unit="$arg"; fi
    done

    case "$verb" in
      show)
        case "$*" in
          *--property=ActiveState*)
            echo "inactive"
            exit 0;;
        esac
        # A unit that exists but has never been started still yields a full
        # property dump (LoadState=loaded, ActiveState=inactive); a unit
        # with no file at all yields the same dump with LoadState=not-found
        # instead. Ansible's module tells those two apart ONCE, up
        # front (`found = is_systemd or is_initd`), and refuses the
        # enabled:/state: steps for the not-found one - so a fake unit has
        # to be able to answer both ways. Only units named
        # nonexistent-* are absent; everything else exists but is inactive.
        echo "Id=$unit"
        echo "Names=$unit"
        case "$unit" in
          nonexistent-*) echo "LoadState=not-found";;
          *)              echo "LoadState=loaded";;
        esac
        echo "ActiveState=inactive"
        echo "SubState=dead"
        echo "UnitFileState="
        exit 0;;
      is-enabled)
        echo "not-found"
        exit 1;;
      *)
        exit 0;;
    esac
  SH
  File.chmod(fake, 0o755)
  PluginSpecHelper.run("systemd", params, env: {"PATH" => "#{bin_dir}:#{ENV["PATH"]? || "/usr/bin:/bin"}"})
end

# The systemd plugin drives the real `systemctl` on the target, so — like the
# `user`/`group` plugins — these tests exercise only the paths that can't
# mutate a real system: pure validation (missing params, invalid state) and
# check-mode predictions. Never run a non-check-mode state/mask/enable call
# here; that would actually start/stop/mask a unit on the dev machine.
describe "systemd plugin" do
  it "fails when no action parameter is given, with Ansible's required_one_of message" do
    # AnsibleModule validation:
    # required_one_of=[['state', 'enabled', 'masked', 'daemon_reload',
    # 'daemon_reexec']]. Replaces the previous ad-hoc guard's own
    # "Must specify at least one of ..." wording.
    result = systemd_run({} of String => String)
    result["failed"].as_bool.must_equal(true)
    result["msg"].to_s.must_equal(
      "one of the following is required: state, enabled, masked, daemon_reload, daemon_reexec")
  end

  # Ansible's name-only query semantics:
  # required_one_of is satisfied by a name alone - the module runs
  # `systemctl show <name>` and populates result['status'] with the unit's
  # current properties, changed stays False, and no management action runs.
  # konstruktoid.hardening's own "Get ctrl-alt-del.target information" task
  # does exactly this (rounds 975062/978000: this used to fail outright with
  # the required_one_of message instead).
  it "treats a name-only task as a query-only call: succeeds unchanged with a populated status dict" do
    result = systemd_run({
      "name"                => "nonexistent-krikri-playbook-unit.service",
      "_ansible_check_mode" => "true",
    })
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["name"].as_s.must_equal("nonexistent-krikri-playbook-unit.service")
    # status is always a dict on success (real: result = dict(status=dict())),
    # populated from `systemctl show` - on a systemd host even a not-found
    # unit yields a property dump (Id=, LoadState=not-found, ...), so the
    # dict is non-empty here; empty only where systemctl itself is absent.
    result["status"].as_h?.wont_be_nil
  end

  it "treats a name-alias-only task (service:) the same way - query-only, unchanged" do
    result = systemd_run({
      "service"             => "nonexistent-krikri-playbook-unit.service",
      "_ansible_check_mode" => "true",
    })
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["name"].as_s.must_equal("nonexistent-krikri-playbook-unit.service")
  end

  it "fails when state is given without a name, with Ansible's required_by message" do
    # required_by={state: name, enabled: name, masked: name} -
    # Ansible's check_required_by wording, per-parameter. Replaces the
    # previous "Must specify 'name' when using ..." wording.
    result = systemd_run({"state" => "started"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].to_s.must_equal("missing parameter(s) required by 'state': name")
  end

  {% for key, value in {"enabled" => "true", "masked" => "true"} %}
    it "fails when {{ key.id }} is given without a name, with Ansible's required_by message" do
      result = systemd_run({ {{ key.id.stringify }} => {{ value.id.stringify }} })
      result["failed"].as_bool.must_equal(true)
      result["msg"].to_s.must_equal("missing parameter(s) required by '{{ key.id }}': name")
    end
  {% end %}

  it "accepts force: with enabled: in check mode (flags only affect the real invocations)" do
    result = systemd_run({
      "name"                => "inactive-krikri-playbook-unit.service",
      "enabled"             => "true",
      "force"               => "true",
      "_ansible_check_mode" => "true",
    })
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["msg"].to_s.must_include("enable")
  end

  it "accepts no_block: with state: started in check mode (flags only affect the real invocations)" do
    result = systemd_run({
      "name"                => "inactive-krikri-playbook-unit.service",
      "state"               => "started",
      "no_block"            => "yes",
      "_ansible_check_mode" => "true",
    })
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["msg"].to_s.must_include("start")
  end

  # Real bug found via round 813233 (role libre_ops.multi_redis): the
  # role passes `systemd: {name: ..., status: ...}` - `status` is not a
  # parameter of Ansible's systemd module at all
  # so
  # ansible-playbook rejects the task outright at argument-spec
  # validation time, before the module runs. This plugin previously
  # silently accepted and ignored the unknown key and ran anyway.
  it "rejects an unsupported parameter with Ansible's argument-spec message" do
    result = systemd_run({
      "name"   => "foo.service",
      "state"  => "started",
      "status" => "yes",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].to_s.must_equal(
      "Unsupported parameters for (systemd) module: status. " \
      "Supported parameters include: daemon_reexec, daemon_reload, enabled, force, masked, name, no_block, scope, state " \
      "(daemon-reexec, daemon-reload, service, unit).")
  end

  it "sorts multiple unsupported parameters alphabetically in Ansible's argument-spec message" do
    result = systemd_run({
      "name"    => "foo.service",
      "state"   => "started",
      "status"  => "yes",
      "pattern" => "foo*",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].to_s.must_equal(
      "Unsupported parameters for (systemd) module: pattern, status. " \
      "Supported parameters include: daemon_reexec, daemon_reload, enabled, force, masked, name, no_block, scope, state " \
      "(daemon-reexec, daemon-reload, service, unit).")
  end

  it "rejects an invalid state" do
    result = systemd_run({"name" => "krikri-playbook-unit.service", "state" => "frobnitz"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].to_s.must_include("Invalid state")
  end

  it "predicts a daemon-reload in check mode without touching the system, reporting unchanged" do
    # Verified against a ansible-playbook --check run of a bare
    # `systemd: {daemon_reload: true}` task: Ansible's own module
    # has no notion of daemon-reload "changedness" and always reports
    # `ok:`, in check mode and for real.
    result = systemd_run({"daemon_reload" => "true", "_ansible_check_mode" => "true"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
  end

  it "predicts a daemon-reexec in check mode without touching the system, reporting unchanged" do
    # Real bug found benchmarking robertdebock.mysql's own "Systemctl
    # daemon-reexec" handler: `ansible.builtin.systemd: {daemon_reexec:
    # true}`, no other params at all (round 18). `daemon_reexec` was
    # entirely unrecognized before - fell into the "no action" guard
    # and failed outright instead of running the reexec
    # ansible-playbook performs (same "no changed signal" semantics as
    # daemon_reload above).
    result = systemd_run({"daemon_reexec" => "true", "_ansible_check_mode" => "true"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
  end

  it "predicts a start for a stopped unit in check mode" do
    result = systemd_run({
      "name"                => "inactive-krikri-playbook-unit.service",
      "state"               => "started",
      "_ansible_check_mode" => "true",
    })
    # This is a unit that exists (LoadState=loaded) but has never been
    # started, so check mode predicts a change — and never actually runs
    # systemctl. A unit that does NOT exist would fail outright with
    # Ansible's "Could not find the requested service ...: host" instead,
    # which the specs further down cover.
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
  end

  # Real bug found benchmarking konstruktoid.docker_rootless (0.9.619):
  # `scope: user` (Ansible's `systemd_service`/`systemd` parameter
  # for targeting the invoking user's OWN systemd session manager - the
  # idiomatic way a rootless-Docker/Podman role enables its own user
  # unit) was completely unhandled: every `systemctl` call always hit
  # the SYSTEM manager regardless, so `konstruktoid.docker_rootless`'s
  # own "Enable and start Docker" (`scope: user`) failed outright
  # ("Unit file docker.service does not exist" - looking at the system
  # namespace instead of `~/.config/systemd/user/docker.service`).
  # Live-verified end-to-end against a real per-user systemd unit
  # (enable+start actually took effect under `systemctl --user`) - this
  # spec only checks `scope: user` is accepted and handled like any
  # other query, staying inside this file's own no-real-mutation
  # convention.
  it "accepts scope: user without rejecting the parameter" do
    result = systemd_run({
      "name"                => "inactive-krikri-playbook-user-unit.service",
      "state"               => "started",
      "scope"               => "user",
      "_ansible_check_mode" => "true",
    })
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
  end

  # Real bug found benchmarking mdsketch.teleport: its own
  # "Reload_Teleport" handler (`ansible.builtin.systemd: {name: teleport,
  # state: reloaded, daemon_reload: yes, enabled: yes}`) fired on a fresh
  # install where the unit file was created in the same play and the
  # service had never started. Ansible's systemd module STARTS an
  # inactive unit for `state: reloaded` (plain `systemctl reload` of an
  # inactive unit fails "is not active, cannot reload" - exactly the
  # error krikri's handler died with); krikri ran the reload
  # unconditionally and failed. Same semantics plugins/service.cr already
  # implements for the `service` module's `state: reloaded`. Check mode
  # on an existing-but-inactive unit must therefore predict a START, not a
  # reload.
  it "predicts a start (not a reload) for an inactive unit with state: reloaded in check mode" do
    result = systemd_run({
      "name"                => "inactive-krikri-playbook-unit.service",
      "state"               => "reloaded",
      "_ansible_check_mode" => "true",
    })
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(true)
    result["msg"].to_s.must_include("start")
    result["msg"].to_s.wont_include("reload")
  end

  # Real bug found via round 903000 (konstruktoid.hardening's own
  # tasks/timesyncd.yml): the role registers the systemd_service result and
  # its changed_when reads the TOP-LEVEL `enabled`/`state` fields
  # Ansible's module returns (systemd_service.py: `result['enabled'] = ...`
  # / `result['state'] = module.params['state']`, siblings of the nested
  # `status` dict). This plugin only ever returned the nested `status`,
  # so `not timesyncd_start.enabled == true` failed the task with
  # "object of type 'dict' has no attribute 'enabled'" while
  # ansible-playbook ran the same task fine.
  describe "top-level result fields (Ansible's systemd_service shape)" do
    it "exposes enabled as a top-level bool when the enabled param was given" do
      result = systemd_run({
        "name"                => "inactive-krikri-playbook-unit.service",
        "enabled"             => "true",
        "_ansible_check_mode" => "true",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      # check mode predicts the enable, so the reported enabled state is
      # the post-change one (Ansible sets result['enabled'] = not
      # enabled outside its check_mode guard)
      result["enabled"].as_bool.must_equal(true)
      result["name"].as_s.must_equal("inactive-krikri-playbook-unit.service")
      # status is always a dict on success (real: result = dict(status=dict()))
      result["status"].as_h?.wont_be_nil
    end

    it "exposes the requested state as a top-level string when state was given" do
      result = systemd_run({
        "name"                => "inactive-krikri-playbook-unit.service",
        "state"               => "started",
        "_ansible_check_mode" => "true",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["state"].as_s.must_equal("started")
      # ...and omits enabled when the enabled param was not given
      result["enabled"]?.must_be_nil
    end

    it "normalizes restarted/reloaded to 'started' in the top-level state" do
      # real: result['state'] = 'started' inside the ActiveState branch,
      # for every requested state - the requested 'restarted'/'reloaded'
      # never survives verbatim
      {"restarted", "reloaded"}.each do |requested|
        result = systemd_run({
          "name"                => "inactive-krikri-playbook-unit.service",
          "state"               => requested,
          "_ansible_check_mode" => "true",
        })
        falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
        result["state"].as_s.must_equal("started")
      end
    end

    it "omits both fields (and reports an empty status dict) for a daemon_reload-only task" do
      result = systemd_run({
        "daemon_reload"       => "true",
        "_ansible_check_mode" => "true",
      })
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["enabled"]?.must_be_nil
      result["state"]?.must_be_nil
      result["status"].as_h.size.must_equal(0)
    end
  end
end

# Builds a throwaway fake `systemctl` that reproduces every
# no-service-manager stderr shape (never touching the dev machine's own
# systemd), first on the child's PATH.
private def with_fake_systemctl(params : Hash(String, String)) : JSON::Any
  bin_dir = PluginSpecHelper.tmp_path("fake-systemctl-bin")
  FileUtils.mkdir_p(bin_dir)
  fake = File.join(bin_dir, "systemctl")
  File.write(fake, <<-SH)
    #!/bin/sh
    for arg in "$@"; do
      case "$arg" in
        --global) echo "--global is not supported for this operation." >&2; exit 1;;
        --user) echo "Failed to connect to user scope bus via local transport: No such file or directory" >&2; exit 1;;
      esac
    done
    echo "System has not been booted with systemd as init system (PID 1). Can't operate." >&2
    echo "Failed to connect to system scope bus via local transport: Host is down" >&2
    exit 1
    SH
  File.chmod(fake, 0o755)
  PluginSpecHelper.run("systemd", params, env: {"PATH" => "#{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin"})
end

# `command -v systemctl` resolves the fake binary on the test's PATH (as
# Ansible's get_bin_path would); pin the prefix so the expectations still read
# like the live-verified "/usr/bin/systemctl ..." strings.
def normalize_systemctl(cmd : String) : String
  cmd.sub(/\A\S*\/systemctl\b/, "/usr/bin/systemctl")
end

# The no-service-manager failure path (Ansible's bare
# `module.run_command(systemctl, check_rc=True)` fallback after
# show/is-enabled/list-unit-files all fail): its echoed cmd carries the
# FULL prefix the module builds once up front - scope flag, then
# --no-block, then --force (systemd_service.py:377-386; live-verified vs
# 2.19.11: force → "/usr/bin/systemctl --force", no_block+force →
# "/usr/bin/systemctl --no-block --force", scope user+force →
# "/usr/bin/systemctl --user --force").
describe "systemd plugin - no-service-manager failure cmd" do
  it "echoes --force in the failure cmd, with Ansible's run_command result shape" do
    result = with_fake_systemctl({"name" => "ssh.service", "force" => "true"})
    result["failed"].as_bool.must_equal(true)
    normalize_systemctl(result["cmd"].as_s).must_equal("/usr/bin/systemctl --force")
    result["rc"].as_i.must_equal(1)
    result["msg"].as_s.must_equal("System has not been booted with systemd as init system (PID 1). Can't operate." \
                                  "\nFailed to connect to system scope bus via local transport: Host is down")
    result["stderr"].as_s.must_equal("System has not been booted with systemd as init system (PID 1). Can't operate." \
                                     "\nFailed to connect to system scope bus via local transport: Host is down\n")
    result["stderr_lines"].as_a.size.must_equal(2)
    result["stdout"].as_s.must_equal("")
    result["stdout_lines"].as_a.must_equal([] of JSON::Any)
  end

  it "echoes --no-block before --force" do
    result = with_fake_systemctl({"name" => "ssh.service", "force" => "true", "no_block" => "true"})
    normalize_systemctl(result["cmd"].as_s).must_equal("/usr/bin/systemctl --no-block --force")
  end

  it "echoes the scope flag first for scope: user (with the user-bus failure msg)" do
    result = with_fake_systemctl({"name" => "ssh.service", "scope" => "user", "force" => "true"})
    result["failed"].as_bool.must_equal(true)
    normalize_systemctl(result["cmd"].as_s).must_equal("/usr/bin/systemctl --user --force")
    result["msg"].as_s.must_equal("Failed to connect to user scope bus via local transport: No such file or directory")
  end

  it "fails scope: global with systemctl's own --global rejection and the prefix in cmd" do
    result = with_fake_systemctl({"name" => "ssh.service", "scope" => "global", "no_block" => "true"})
    result["failed"].as_bool.must_equal(true)
    normalize_systemctl(result["cmd"].as_s).must_equal("/usr/bin/systemctl --global --no-block")
    result["msg"].as_s.must_equal("--global is not supported for this operation.")
    result["stderr_lines"].as_a.size.must_equal(1)
  end

  it "keeps the state-management failure on the same failure path (cmd carries --force)" do
    result = with_fake_systemctl({"name" => "ssh.service", "state" => "started", "force" => "true"})
    result["failed"].as_bool.must_equal(true)
    normalize_systemctl(result["cmd"].as_s).must_equal("/usr/bin/systemctl --force")
  end
end

# A throwaway fake `systemctl` for a host where the unit the task names has
# NO unit file at all: `show` answers the full property dump Ansible's systemd
# gives for an absent unit (LoadState=not-found), is-enabled answers
# "not-found", and every state-changing verb is logged so the ORDER of
# operations is observable - the dev machine's own systemd is never
# touched (nothing here ever reaches a real systemctl binary).
private def with_missing_unit_systemctl(params : Hash(String, String), &)
  bin_dir = PluginSpecHelper.tmp_path("missing-unit-systemctl-bin")
  FileUtils.mkdir_p(bin_dir)
  log = File.join(bin_dir, "calls.log")
  fake = File.join(bin_dir, "systemctl")
  File.write(fake, <<-SH)
    #!/bin/sh
    echo "$@" >> "$KRIKRI_SYSTEMD_CALLS"
    verb=""
    for arg in "$@"; do
      case "$arg" in
        -*) continue;;
      esac
      if [ -z "$verb" ]; then verb="$arg"; fi
    done

    case "$verb" in
      show)
        case "$*" in
          *--property=ActiveState*) echo "inactive"; exit 0;;
        esac
        # A unit with no file at all still yields a full property dump on a
        # real systemd host - LoadState=not-found is the only difference.
        echo "Id=missing-krikri-playbook-unit.service"
        echo "LoadState=not-found"
        echo "ActiveState=inactive"
        exit 0;;
      is-enabled)
        echo "not-found"
        exit 1;;
      *)
        # mask/unmask/disable/stop all "succeed" here, exactly as they do on
        # a real host for a unit that isn't installed - which is the whole
        # point: only Ansible's fail_if_missing stands between this and a
        # `changed` report.
        exit 0;;
    esac
  SH
  File.chmod(fake, 0o755)
  result = PluginSpecHelper.run("systemd", params,
    env: {"PATH" => "#{bin_dir}:#{ENV["PATH"]? || "/usr/bin:/bin"}", "KRIKRI_SYSTEMD_CALLS" => log})
  yield result, File.exists?(log) ? File.read_lines(log) : [] of String
end

# Ansible's systemd module computes `found = is_systemd or is_initd`
# ONCE, before it acts on the unit, and calls fail_if_missing(module, found,
# unit, msg='host') at the top of both the `enabled:` and the `state:`
# block (systemd_service.py; the message itself is
# the Ansible module). It never did that here, so a task
# naming a unit no package installs came back `changed` where Ansible's own
# failed_when - konstruktoid.hardening's kdump.service / kdump-tools.service
# / systemd-journal-remote.* / atd tasks, all of which swallow exactly this
# message - turned it into `ok`. Found on real Ubuntu 22.04 hosts, round
# 999001.
describe "systemd plugin - unit that systemd does not know" do
  it "fails the enabled: step with Ansible's missing-service message, without ever disabling" do
    with_missing_unit_systemctl({
      "name"    => "missing-krikri-playbook-unit.service",
      "enabled" => "false",
    }) do |result, calls|
      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].to_s.must_equal(
        "Could not find the requested service missing-krikri-playbook-unit.service: host")
      calls.compact_map { |line| line.split(" ")[0]? }.wont_include("disable")
    end
  end

  it "fails the state: step with the same message" do
    with_missing_unit_systemctl({
      "name"  => "missing-krikri-playbook-unit.service",
      "state" => "stopped",
    }) do |result, calls|
      result["failed"].as_bool.must_equal(true)
      result["msg"].to_s.must_equal(
        "Could not find the requested service missing-krikri-playbook-unit.service: host")
      calls.compact_map { |line| line.split(" ")[0]? }.wont_include("stop")
    end
  end

  it "still masks the absent unit before failing (Ansible's order: mask block, then fail_if_missing)" do
    # `systemctl mask` succeeds for a unit that isn't installed - it just
    # drops the symlink in /etc/systemd/system - and Ansible really
    # does mask it, so the side effect has to have happened by the time the
    # enabled:/state: failure comes back. This is the exact task shape
    # konstruktoid.hardening runs on kdump.service.
    with_missing_unit_systemctl({
      "name"    => "missing-krikri-playbook-unit.service",
      "masked"  => "true",
      "enabled" => "false",
      "state"   => "stopped",
    }) do |result, calls|
      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].to_s.must_equal(
        "Could not find the requested service missing-krikri-playbook-unit.service: host")
      verbs = calls.compact_map { |line| line.split(" ")[0]? }
      verbs.must_include("mask")
      verbs.wont_include("disable")
      verbs.wont_include("stop")
    end
  end

  it "leaves a masked-only task on an absent unit successful and changed" do
    # No enabled:/state: means no fail_if_missing at all - Ansible's
    # own comment on the mask block says so ("can operate on services
    # before they are installed"), so masking something not yet installed
    # is a supported thing to do, not an error.
    with_missing_unit_systemctl({
      "name"   => "missing-krikri-playbook-unit.service",
      "masked" => "true",
    }) do |result, calls|
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      calls.compact_map { |line| line.split(" ")[0]? }.must_include("mask")
    end
  end

  it "fails the same way in check mode (Ansible's fail_if_missing is mode-independent)" do
    with_missing_unit_systemctl({
      "name"                => "missing-krikri-playbook-unit.service",
      "enabled"             => "false",
      "_ansible_check_mode" => "true",
    }) do |result, calls|
      result["failed"].as_bool.must_equal(true)
      result["msg"].to_s.must_equal(
        "Could not find the requested service missing-krikri-playbook-unit.service: host")
      calls.compact_map { |line| line.split(" ")[0]? }.wont_include("disable")
    end
  end

  it "treats a MASKED unit as found - masking is what creates it" do
    # LoadState=masked is still a unit systemd knows about (Ansible's check is
    # only for "not-found"), so an enabled:/state: task on it must run
    # normally rather than report the unit missing.
    bin_dir = PluginSpecHelper.tmp_path("masked-unit-systemctl-bin")
    FileUtils.mkdir_p(bin_dir)
    fake = File.join(bin_dir, "systemctl")
    File.write(fake, <<-SH)
      #!/bin/sh
      verb=""
      for arg in "$@"; do
        case "$arg" in
          -*) continue;;
        esac
        if [ -z "$verb" ]; then verb="$arg"; fi
      done
      case "$verb" in
        show)
          case "$*" in
            *--property=ActiveState*) echo "inactive"; exit 0;;
          esac
          echo "Id=masked-krikri-playbook-unit.service"
          echo "LoadState=masked"
          echo "ActiveState=inactive"
          exit 0;;
        is-enabled)
          echo "masked"
          exit 1;;
        *) exit 0;;
      esac
    SH
    File.chmod(fake, 0o755)
    result = PluginSpecHelper.run("systemd", {
      "name"                => "masked-krikri-playbook-unit.service",
      "state"               => "stopped",
      "_ansible_check_mode" => "true",
    }, env: {"PATH" => "#{bin_dir}:#{ENV["PATH"]? || "/usr/bin:/bin"}"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end
end
