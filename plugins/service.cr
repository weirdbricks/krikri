#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Service Plugin - Manage system services
  #
  # Parameters:
  #   name (required): Service name
  #   state (optional): started, stopped, restarted, reloaded
  #   enabled (optional): yes/no - enable on boot
  #   use (optional): force a service manager (systemd/sysvinit/service/
  #                   openrc/auto) instead of auto-detecting
  #   runlevel (optional): OpenRC runlevel for enable/disable (default:
  #                        "default") - real Ansible's own param
  #   check_mode (optional): Dry-run mode
  #
  # Examples:
  #   service:
  #     name: nginx
  #     state: started
  #     enabled: yes
  #
  # Init-system detection: real Ansible's `service:` is a WRAPPER, not a
  # systemd module. Its action plugin dispatches on the
  # `ansible_service_mgr` fact (or an explicit `use:`), and when that
  # doesn't name a loadable module it falls through to the generic
  # `service` module, which detects the init system itself and drives
  # SysV init scripts / OpenRC / upstart instead. This plugin previously
  # ran `systemctl` unconditionally, so on any host where systemd is not
  # PID 1 every `service:` task failed with systemctl's own "System has
  # not been booted with systemd as init system (PID 1). Can't operate."
  # where real Ansible succeeded via `service <name> start`. Found while
  # confirming the 0.9.726 fixes in a container (no init at all): both
  # engines were expected to agree and only krikri failed.
  class ServicePlugin < BasePlugin
    property? check_mode : Bool

    # Which init system drives this service. Mirrors the branches of real
    # Ansible's `LinuxService.get_service_tools`, in its order.
    enum Manager
      Systemd
      Upstart
      OpenRC
      SysV
    end

    # Binaries real Ansible looks for, and the extra directories it
    # searches beyond `$PATH` (`get_bin_path`'s `opt_dirs`) - `/sbin` and
    # `/usr/sbin` are routinely absent from a non-login shell's PATH,
    # which is exactly where `service`/`update-rc.d` live.
    TOOL_BINARIES  = %w[service chkconfig update-rc.d rc-service rc-update initctl systemctl insserv]
    EXTRA_BIN_DIRS = %w[/sbin /usr/sbin /bin /usr/bin]

    @tools = Hash(String, String).new
    @manager : Manager = Manager::Systemd
    @svc_cmd : String? = nil
    @enable_cmd : String? = nil
    @svc_initscript : String? = nil
    @rc_start_links = 0
    @rc_kill_links = 0
    @systemd_load_state = ""
    @systemd_active_state = ""

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["check_mode"]?)
    end

    def execute : PluginResult
      # Validate required parameters
      name = @params["name"]?
      unless name
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Missing required parameter: name"
        )
      end

      state = @params["state"]?
      enabled = @params["enabled"]?

      # Must have at least one action
      unless state || enabled
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Must specify 'state' or 'enabled'"
        )
      end

      if state && !{"started", "stopped", "restarted", "reloaded"}.includes?(state)
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: "Invalid state: #{state}. Must be started, stopped, restarted, or reloaded"
        )
      end

      if error = detect_service_tools(name)
        return PluginResult.new(changed: false, failed: true, msg: error)
      end

      changed = false
      messages = [] of String

      # Handle enabled/disabled
      if enabled
        result = set_enabled(name, true?(enabled))
        if failure = result[:failure]
          return failure
        end
        changed ||= result[:changed]
        messages << result[:message] unless result[:message].empty?
      end

      # Handle state
      if state
        result = set_state(name, state)
        if failure = result[:failure]
          return failure
        end
        changed ||= result[:changed]
        messages << result[:message] unless result[:message].empty?
      end

      msg = messages.empty? ? "No changes needed" : messages.join(", ")
      if @check_mode && !messages.empty?
        msg += " (check mode)"
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg
      )
    end

    # ------------------------------------------------------------------
    # Detection
    # ------------------------------------------------------------------

    # Populates @manager/@svc_cmd/@enable_cmd/@svc_initscript, following
    # real Ansible's `LinuxService.get_service_tools`. Returns an error
    # message when no usable tooling exists, nil otherwise.
    #
    # One round trip: everything the Python module reads via os.path/
    # get_bin_path is gathered by a single probe script instead, because
    # this plugin talks to the host through #remote_exec rather than
    # touching the filesystem directly (it runs controller-side for a
    # local connection, and is uploaded and run on the target otherwise -
    # in both cases only #remote_exec is guaranteed to reach the host
    # whose services these are).
    private def detect_service_tools(name : String) : String?
      probe = probe_output(name)

      probe.each_line do |line|
        key, _, value = line.strip.partition('=')
        case key
        when .starts_with?("bin:")
          @tools[key.lchop("bin:")] = value unless value.empty?
        when "initscript"
          @svc_initscript = value unless value.empty?
        when "rc_start_links"
          @rc_start_links = value.to_i? || 0
        when "rc_kill_links"
          @rc_kill_links = value.to_i? || 0
        end
      end

      systemd = probe.includes?("systemd_managed=yes")
      upstart_conf = probe.includes?("upstart_conf=yes")

      # `use:` - real Ansible's own escape hatch, handled in its action
      # plugin (which strips the param before the module ever sees it).
      # "auto" is the default and means detect; anything else pins the
      # manager, so a role that knows better than the probe still wins.
      case @params["use"]?.try(&.downcase)
      when "systemd"
        return use_systemd(name)
      when "sysvinit", "service"
        return use_sysv(name)
      when "openrc"
        return use_openrc
      when "upstart"
        return use_upstart
      end

      if systemd && @tools["systemctl"]?
        use_systemd(name)
      elsif upstart_conf && @tools["initctl"]?
        use_upstart
      elsif @tools["rc-service"]?
        use_openrc
      else
        use_sysv(name)
      end
    end

    # Real Ansible's `systemd` module reads the unit's status ONCE at the
    # top of the run and reuses it for both the enabled: and state:
    # decisions, so this does the same - one `systemctl show` instead of
    # one per branch.
    private def use_systemd(name : String) : String?
      @manager = Manager::Systemd
      cmd = @tools["systemctl"]? || "systemctl"
      @svc_cmd = cmd
      @enable_cmd = cmd

      remote_exec("#{cmd} show #{name} --property=LoadState --property=ActiveState 2>/dev/null")[:stdout].to_s.each_line do |line|
        key, _, value = line.strip.partition('=')
        case key
        when "LoadState"   then @systemd_load_state = value
        when "ActiveState" then @systemd_active_state = value
        end
      end

      # fail_if_missing, the systemd module's own copy: a unit that
      # neither systemd nor /etc/init.d knows about is reported by name
      # ("Could not find the requested service nope: host") rather than
      # left to whatever systemctl says about the missing unit. Verified
      # against ansible-core 2.19 on a real systemd host - the generic
      # `service` module and the `systemd` module share this message, so
      # a typo'd service name reads the same either side of the
      # init-system split.
      is_systemd_unit = !@systemd_load_state.empty? && @systemd_load_state != "not-found"
      if !is_systemd_unit && @svc_initscript.nil?
        return "Could not find the requested service #{name}: host"
      end

      nil
    end

    private def use_openrc : String?
      @manager = Manager::OpenRC
      @svc_cmd = @tools["rc-service"]? || "rc-service"
      @enable_cmd = @tools["rc-update"]?
      nil
    end

    # Upstart is detected (so a host running it doesn't get silently
    # driven as SysV) but deliberately NOT implemented: its enable path
    # is an /etc/init/<name>.override file whose contents differ by
    # initctl version, and no currently-supported distro ships it
    # (Ubuntu 14.04, its last home, went EOL in 2019). A clear
    # unsupported error beats guessing at override-file semantics that
    # can't be verified against a live host.
    private def use_upstart : String?
      @manager = Manager::Upstart
      "upstart-managed services are not supported by this engine " \
      "(no supported distro still ships upstart); use the initctl " \
      "commands directly, or set `use:` to another service manager"
    end

    private def use_sysv(name : String) : String?
      @manager = Manager::SysV

      # Enable/disable tool, in real Ansible's own precedence order - and,
      # as there, ONLY when this service actually has an init script.
      # That coupling is what makes a typo'd/nonexistent service name fail
      # with real Ansible's own "Could not find the requested service X:
      # host" (its `fail_if_missing`, reached because no branch of the
      # detection chain matched at all) instead of a confusing error from
      # whatever command got run against a name that doesn't exist.
      # Confirmed live against ansible-core 2.19 with
      # `service: name=definitely-not-a-service state=started`.
      @enable_cmd = @svc_initscript.nil? ? nil : (@tools["update-rc.d"]? || @tools["insserv"]? || @tools["chkconfig"]?)

      # fail_if_missing: real Ansible reports this even for a state-only
      # task, so a host with no init script (or one with a script but no
      # way to enable it) fails identically here.
      if @enable_cmd.nil?
        return "Could not find the requested service #{name}: host"
      end

      @svc_cmd = @tools["service"]?

      if @svc_cmd.nil? && @svc_initscript.nil?
        return "cannot find 'service' binary or init script for service,  possible typo in service name?, aborting"
      end

      nil
    end

    # Single shell probe replacing real Ansible's get_bin_path/os.path
    # lookups. `systemd_managed` mirrors module_utils' own
    # `is_systemd_managed`: systemctl present, then systemd's documented
    # sd_booted canaries, then /proc/1/comm - NOT merely "systemctl
    # exists", which is what made this plugin drive systemctl on hosts
    # where systemd is installed but isn't PID 1 (any container, a
    # chroot, a sysvinit host with the systemd package pulled in).
    private def probe_output(name : String) : String
      quoted = shell_quote(name)
      script = <<-SH
      for b in #{TOOL_BINARIES.join(' ')}; do
        found=""
        for d in $(printf '%s' "$PATH" | tr ':' ' ') #{EXTRA_BIN_DIRS.join(' ')}; do
          if [ -x "$d/$b" ]; then found="$d/$b"; break; fi
        done
        printf 'bin:%s=%s\\n' "$b" "$found"
      done
      managed=no
      if [ -n "$(command -v systemctl 2>/dev/null)" ] || [ -x /usr/bin/systemctl ] || [ -x /bin/systemctl ]; then
        for canary in /run/systemd/system/ /dev/.run/systemd/ /dev/.systemd/; do
          if [ -e "$canary" ]; then managed=yes; break; fi
        done
        if [ "$managed" = no ] && [ "$(cat /proc/1/comm 2>/dev/null)" = systemd ]; then managed=yes; fi
      fi
      printf 'systemd_managed=%s\\n' "$managed"
      if [ -x /etc/init.d/#{quoted} ]; then printf 'initscript=/etc/init.d/%s\\n' #{quoted}; else printf 'initscript=\\n'; fi
      if [ -e /etc/init/#{quoted}.conf ]; then printf 'upstart_conf=yes\\n'; else printf 'upstart_conf=no\\n'; fi
      printf 'rc_start_links=%s\\n' "$(ls -d /etc/rc?.d/S??#{quoted} 2>/dev/null | wc -l)"
      printf 'rc_kill_links=%s\\n' "$(ls -d /etc/rc?.d/K??#{quoted} 2>/dev/null | wc -l)"
      SH

      remote_exec(script)[:stdout].to_s
    end

    # ------------------------------------------------------------------
    # enabled:
    # ------------------------------------------------------------------

    private def set_enabled(name : String, should_enable : Bool) : NamedTuple(changed: Bool, message: String, failure: PluginResult?)
      enable_cmd = @enable_cmd
      if enable_cmd.nil?
        return failure("cannot detect command to enable service #{name}, typo or init system potentially unknown")
      end

      case
      when enable_cmd.ends_with?("systemctl")   then enable_via_systemctl(name, should_enable)
      when enable_cmd.ends_with?("update-rc.d") then enable_via_update_rc_d(name, should_enable, enable_cmd)
      when enable_cmd.ends_with?("chkconfig")   then enable_via_chkconfig(name, should_enable, enable_cmd)
      when enable_cmd.ends_with?("rc-update")   then enable_via_rc_update(name, should_enable, enable_cmd)
      when enable_cmd.ends_with?("insserv")     then enable_via_insserv(name, should_enable, enable_cmd)
      else
        failure("cannot detect command to enable service #{name}, typo or init system potentially unknown")
      end
    end

    private def enable_via_systemctl(name : String, should_enable : Bool)
      is_enabled = remote_exec("systemctl is-enabled #{name} 2>/dev/null")[:exit_code] == 0
      return unchanged if should_enable == is_enabled

      action = should_enable ? "enable" : "disable"
      return would("#{action} #{name}") if @check_mode

      result = remote_exec("systemctl #{action} #{name}")
      if result[:exit_code] == 0
        changed("Service #{should_enable ? "enabled" : "disabled"}")
      else
        failure("Failed to #{action} service: #{result[:stderr]}")
      end
    end

    # Debian's update-rc.d has no query mode, so real Ansible reads the
    # runlevel symlinks directly: an S?? link in any /etc/rc?.d means
    # enabled. A service with no K?? links at all has never been
    # registered, so `defaults` has to run before `enable` can do
    # anything.
    private def enable_via_update_rc_d(name : String, should_enable : Bool, cmd : String)
      is_enabled = @rc_start_links > 0
      return unchanged if should_enable == is_enabled

      action = should_enable ? "enable" : "disable"
      return would("#{action} #{name}") if @check_mode

      if should_enable && @rc_kill_links == 0
        result = remote_exec("#{cmd} #{name} defaults")
        unless result[:exit_code] == 0
          return failure(result[:stderr].to_s.empty? ? result[:stdout].to_s : result[:stderr].to_s)
        end
      end

      result = remote_exec("#{cmd} #{name} #{action}")
      if result[:exit_code] == 0
        changed("Service #{should_enable ? "enabled" : "disabled"}")
      else
        failure(result[:stderr].to_s.empty? ? result[:stdout].to_s : result[:stderr].to_s)
      end
    end

    private def enable_via_chkconfig(name : String, should_enable : Bool, cmd : String)
      action = should_enable ? "on" : "off"

      listing = remote_exec("#{cmd} --list #{name}")
      out = listing[:stdout].to_s
      if listing[:stderr].to_s.includes?("chkconfig --add #{name}")
        remote_exec("#{cmd} --add #{name}")
        out = remote_exec("#{cmd} --list #{name}")[:stdout].to_s
      end

      unless out.includes?(name)
        return failure("service #{name} does not support chkconfig")
      end

      # Runlevels 3 and 5 are the ones chkconfig reports for the normal
      # multi-user/graphical targets - real Ansible treats agreement on
      # both as "already in the requested state".
      return unchanged if out.includes?("3:#{action}") && out.includes?("5:#{action}")
      return would("#{should_enable ? "enable" : "disable"} #{name}") if @check_mode

      result = remote_exec("#{cmd} #{name} #{action}")
      if result[:exit_code] == 0
        changed("Service #{should_enable ? "enabled" : "disabled"}")
      else
        enable_failure(action, name, result)
      end
    end

    private def enable_via_rc_update(name : String, should_enable : Bool, cmd : String)
      runlevel = @params["runlevel"]? || "default"
      action = should_enable ? "add" : "delete"

      needs_change = !should_enable
      found = false
      remote_exec("#{cmd} show")[:stdout].to_s.each_line do |line|
        service_name, sep, runlevels = line.partition('|')
        next if sep.empty?
        next unless service_name.strip == name
        found = true
        levels = runlevels.split(/\s+/).reject(&.empty?)
        needs_change = should_enable ? !levels.includes?(runlevel) : levels.includes?(runlevel)
        break
      end
      # Never listed at all: already disabled everywhere.
      needs_change = false if !found && !should_enable

      return unchanged unless needs_change
      return would("#{should_enable ? "enable" : "disable"} #{name}") if @check_mode

      result = remote_exec("#{cmd} #{action} #{name} #{runlevel}")
      if result[:exit_code] == 0
        changed("Service #{should_enable ? "enabled" : "disabled"}")
      else
        enable_failure(action, name, result)
      end
    end

    # insserv has no query mode either, but it does have a dry run
    # (`-n -v`) that reports on stderr what it WOULD do - which is how
    # real Ansible decides whether anything needs changing.
    private def enable_via_insserv(name : String, should_enable : Bool, cmd : String)
      dry_run = should_enable ? "#{cmd} -n -v #{name}" : "#{cmd} -n -r -v #{name}"
      marker = should_enable ? "enable service" : "remove service"
      needs_change = remote_exec(dry_run)[:stderr].to_s.each_line.any?(&.includes?(marker))

      return unchanged unless needs_change
      return would("#{should_enable ? "enable" : "disable"} #{name}") if @check_mode

      result = remote_exec(should_enable ? "#{cmd} #{name}" : "#{cmd} -r #{name}")
      if result[:exit_code] != 0 || !result[:stderr].to_s.empty?
        verb = should_enable ? "install" : "remove"
        return failure("Failed to #{verb} service. rc: #{result[:exit_code]}, out: #{result[:stdout]}, err: #{result[:stderr]}")
      end
      changed("Service #{should_enable ? "enabled" : "disabled"}")
    end

    private def enable_failure(action : String, name : String, result)
      if (err = result[:stderr].to_s) && !err.empty?
        failure("Error when trying to #{action} #{name}: rc=#{result[:exit_code]} #{err}")
      else
        failure("Failure for #{action} #{name}: rc=#{result[:exit_code]} #{result[:stdout]}")
      end
    end

    # ------------------------------------------------------------------
    # state:
    # ------------------------------------------------------------------

    private def set_state(name : String, state : String) : NamedTuple(changed: Bool, message: String, failure: PluginResult?)
      is_running = service_running?(name)

      case state
      when "started"
        return unchanged if is_running
        return would("start #{name}") if @check_mode
        run_action(name, "start", "Service started")
      when "stopped"
        return unchanged unless is_running
        return would("stop #{name}") if @check_mode
        run_action(name, "stop", "Service stopped")
      when "restarted"
        return would("restart #{name}") if @check_mode
        run_action(name, "restart", "Service restarted")
      else # "reloaded" - validated by the caller
        return would("reload #{name}") if @check_mode
        run_action(name, "reload", "Service reloaded")
      end
    end

    private def service_running?(name : String) : Bool
      case @manager
      when Manager::Systemd
        # `systemctl is-active` only exits 0 for ActiveState=active - a unit
        # that's `activating`/`auto-restart` (e.g. crash-looping under
        # Restart=on-failure) exits non-zero even though real Ansible's
        # systemd module already considers it "running" and won't reissue
        # `start` for it. Read the raw ActiveState instead (captured by
        # #use_systemd's single status read) so a crash-looping unit
        # doesn't get restarted (and reported changed) on every run.
        {"active", "activating"}.includes?(@systemd_active_state)
      when Manager::OpenRC
        result = remote_exec("#{@svc_cmd} #{name} status")
        result[:stdout].to_s.includes?("started")
      else
        sysv_running?(name)
      end
    end

    # Real Ansible's own SysV status heuristics, in its order: LSB exit
    # codes first, then single-line keyword matching, then "rc=0 means
    # running". Init scripts are wildly inconsistent about all three,
    # which is why the fallbacks exist at all - reproducing them is what
    # keeps a `state: started` task idempotent against a real init script
    # rather than restarting the service on every run.
    private def sysv_running?(name : String) : Bool
      result = run_sysv(name, "status")
      rc = result[:exit_code]
      stdout = result[:stdout].to_s

      # http://refspecs.linuxbase.org/LSB_4.1.0/LSB-Core-generic/LSB-Core-generic/iniscrptact.html
      return false if {1, 2, 3, 4, 69}.includes?(rc)

      # Only trust keywords from a single line: a failing init script can
      # be verbose enough to hit a keyword by accident.
      if stdout.count('\n') <= 1
        cleanout = stdout.downcase.gsub(name.downcase, "")
        return false if cleanout.includes?("stop")
        return !cleanout.includes?("not ") if cleanout.includes?("run")
        return true if cleanout.includes?("start") && !cleanout.includes?("not ")
        return false if cleanout.includes?("could not access pid file")
        return false if cleanout.includes?("is dead and pid file exists")
        return false if cleanout.includes?("dead but subsys locked")
        return false if cleanout.includes?("dead but pid file exists")
      end

      return true if rc == 0

      # iptables' status output carries no usable rc or keyword at all.
      return true if name == "iptables" && stdout.includes?("ACCEPT")

      false
    end

    private def run_action(name : String, action : String, success_message : String)
      result =
        case @manager
        when Manager::Systemd
          remote_exec("systemctl #{action} #{name}")
        when Manager::OpenRC
          # Every OpenRC service supports restart natively.
          remote_exec("#{@svc_cmd} #{name} #{action}")
        else
          if action == "restart"
            # Real Ansible does NOT trust a SysV init script to implement
            # `restart` - plenty don't - and issues stop-then-start
            # instead, merging the two results the same way.
            first = run_sysv(name, "stop")
            second = run_sysv(name, "start")
            if first[:exit_code] != 0 && second[:exit_code] == 0
              second
            else
              {exit_code: first[:exit_code] + second[:exit_code],
               stdout:    first[:stdout].to_s + second[:stdout].to_s,
               stderr:    first[:stderr].to_s + second[:stderr].to_s}
            end
          else
            run_sysv(name, action)
          end
        end

      if result[:exit_code] == 0
        changed(success_message)
      else
        verb = action == "start" ? "start" : action
        failure("Failed to #{verb} service: #{result[:stderr].to_s.empty? ? result[:stdout] : result[:stderr]}")
      end
    end

    # `service <name> <action>`, or the init script directly when no
    # `service` binary exists - real Ansible's own two SysV command forms.
    private def run_sysv(name : String, action : String)
      if svc_cmd = @svc_cmd
        remote_exec("#{svc_cmd} #{name} #{action}")
      else
        remote_exec("#{@svc_initscript} #{action}")
      end
    end

    # ------------------------------------------------------------------
    # Small result helpers - every enabled:/state: branch returns one of
    # these so #execute can stay a straight accumulation.
    # ------------------------------------------------------------------

    private def unchanged
      {changed: false, message: "", failure: nil.as(PluginResult?)}
    end

    private def changed(message : String)
      {changed: true, message: message, failure: nil.as(PluginResult?)}
    end

    private def would(description : String)
      {changed: true, message: "Would #{description}", failure: nil.as(PluginResult?)}
    end

    private def failure(msg : String)
      {changed: false, message: "",
       failure: PluginResult.new(changed: false, failed: true, msg: msg).as(PluginResult?)}
    end

    private def shell_quote(value : String) : String
      "'" + value.gsub("'", "'\\''") + "'"
    end

    # Helper to convert string/bool to boolean
    private def true?(value) : Bool
      return false if value.nil?
      value_str = value.to_s.downcase
      value_str == "true" || value_str == "yes" || value_str == "1"
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::ServicePlugin.new(config)
plugin.run
