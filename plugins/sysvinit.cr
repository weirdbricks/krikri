#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # ansible.builtin.sysvinit - SysV service management (ansible-core's
  # modules/sysvinit.py, ported from the 2.19.11 install).
  #
  # Before this plugin the module took the graceful unavailable-module
  # skip (issue #900, found by krikri-playbook-generator's sysvinit chaos
  # class): real runs the module, whose AnsibleModule init fails on the
  # required_one_of [['state', 'enabled']] check the moment a task passes
  # only name: - "one of the following is required: state, enabled" -
  # while krikri skipped the task and exited rc=4. That init-time failure
  # is produced controller-side by ArgspecValidator off the generated
  # spec table entry; this plugin mirrors the module's own run.
  #
  # Everything the module reads through os.path/glob/get_bin_path is
  # gathered by ONE probe script (this plugin talks to the host through
  # #remote_exec rather than touching the filesystem directly - it runs
  # controller-side for a local connection and on the target otherwise),
  # then every module run_command is replayed through #remote_exec with
  # the module's exact (deliberately unquoted) command strings - the
  # module builds them with raw % interpolation, so a service name with
  # shell metacharacters reaches the init script identically here.
  class SysvinitPlugin < BasePlugin
    @warnings = [] of String

    # The run_command triple, carried between the module's sections the
    # same way sysvinit.py's local rc/out/err are: the status probe seeds
    # them (or they keep their 0/''/'' init when the pattern: path skips
    # the status command), the enable command overwrites them, and the
    # state runme overwrites them again. The result's status dict
    # snapshots them at two distinct points - the enabled section copies
    # them aside when it changed, resetting the trio to None - which is
    # why a changed enable followed by an unchanged state leaves the
    # state entry all-null.
    @rc = 0
    @out = ""
    @err = ""

    def execute : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      # Module params, post-argspec: the controller's ArgspecValidator
      # already rejected choice/type/required_one_of violations. An
      # explicitly null param rides as Python None, not "".
      name = @params["name"]? || @params["service"]? || ""
      state : String? = explicit_null_param?("state") || !@params.has_key?("state") ? nil : @params["state"]
      enabled : Bool? = if explicit_null_param?("enabled") || !@params.has_key?("enabled")
        nil
      else
        true?(@params["enabled"])
      end
      runlevels : Array(String)? = explicit_null_param?("runlevels") ? nil : parse_runlevels
      # Python's `if runlevels:` treats an EMPTY list as no-runlevels:
      # the base (no-runlevel) glob and the `enabled is not None` branch
      # apply, and the status dict carries no runlevels key.
      runlevels = nil if runlevels.try(&.empty?)
      pattern : String? = explicit_null_param?("pattern") || !@params.has_key?("pattern") ? nil : @params["pattern"]
      arguments : String? = explicit_null_param?("arguments") ? nil : (@params["arguments"]? || @params["args"]?)
      daemonize : Bool = !explicit_null_param?("daemonize") && @params.has_key?("daemonize") &&
        true?(@params["daemonize"])
      sleep_for : Int32? = 1
      if @params.has_key?("sleep")
        sleep_for = explicit_null_param?("sleep") ? nil : @params["sleep"].to_i?
      end
      check_mode = true?(@params["_ansible_check_mode"]?)

      # get_sysv_script: a name that is itself a path is used verbatim.
      script = name.starts_with?('/') ? name : "/etc/init.d/#{name}"

      probe = probe_host(name, runlevels)

      # fail_if_missing(sysv_exists(name), name): a plain fail_json whose
      # msg suffix is the caller's empty extra - the trailing ": " is
      # real's exact text (live-verified vs 2.19.11).
      unless probe.script_exists
        return fail_plain("Could not find the requested service #{name}: ")
      end

      runlevel_status = Hash(String, Bool).new
      if rls = runlevels
        rls.each { |runlevel| runlevel_status[runlevel] = probe.runlevel_enabled[runlevel]? == 1 }
      else
        runlevel_status["enabled"] = probe.rc_glob_count > 0
      end

      # Status detection - "everyone does it different" (the module's own
      # comment): a pattern: match over ps output, else `service <name>
      # status` (or the init script's own status), then the rc/output
      # heuristics and the ps hail-mary.
      is_started = false
      worked = false

      if pattern
        ps_match = get_ps(pattern)
        if ps_match.is_a?(PluginResult)
          return ps_match
        end
        worked = is_started = ps_match
      else
        cmd = if service_path = probe.bins["service"]?
                "#{service_path} #{name} status"
              else
                "#{script} status"
              end
        run_command(cmd)

        # The rc == -1 fork-failure case is unreachable here (every
        # command ran through #remote_exec or failed with a real rc).
        if name == "iptables" && @out.includes?("ACCEPT")
          worked = true
          is_started = true
        end

        unless worked
          if @out.count('\n') <= 1
            cleanout = @out.downcase.gsub(name.downcase, "")

            {"stop", "is dead ", "dead but ", "could not access pid file", "inactive"}.each do |stopped|
              if cleanout.includes?(stopped)
                worked = true
                break
              end
            end

            unless worked
              {"run", "start", "active"}.each do |started_status|
                if cleanout.includes?(started_status) && !cleanout.includes?("not ")
                  is_started = true
                  worked = true
                  break
                end
              end
            end
          end

          unless worked
            worked = [1, 2, 3, 4, 69].includes?(@rc)
          end

          unless worked
            if @rc == 0
              is_started = true
              worked = true
            else
              ps_match = get_ps(name)
              if ps_match.is_a?(PluginResult)
                return ps_match
              end
              if ps_match
                is_started = true
                worked = true
                @warnings << "Used ps output to match service name and determine it is up, this is very unreliable"
              end
            end
          end
        end
      end

      @warnings << "Unable to determine if service is up, assuming it is down" unless worked

      changed = false

      # ----------------------------------------------------------------
      # Enable/Disable - status['enabled'] always exists.
      # ----------------------------------------------------------------
      status_enabled = status_entry
      if rls = runlevels
        status_enabled["runlevels"] = json_string_array(rls)
        rls.each do |runlevel|
          # An absent enabled: is Python None here, and None != <bool>
          # counts as a change - the module then takes the DISABLE path
          # (`if enabled:` is falsy) even though no enabled: was given.
          if enabled != runlevel_status[runlevel]?
            changed = true
            status_enabled["changed"] = JSON::Any.new(true)
          end
        end

        if !check_mode && changed
          if enabled
            if updatercd = probe.bins["update-rc.d"]?
              run_command("#{updatercd} #{name} enable #{rls.join(" ")}")
            elsif chkconfig = probe.bins["chkconfig"]?
              run_command("#{chkconfig} --level #{rls.join} #{name} on")
            end
          else
            if updatercd = probe.bins["update-rc.d"]?
              run_command("#{updatercd} #{name} disable #{rls.join(" ")}")
            elsif chkconfig = probe.bins["chkconfig"]?
              run_command("#{chkconfig} --level #{rls.join} #{name} off")
            end
          end
        end
      else
        # The no-runlevels branch gates on `enabled is not None`: an
        # explicitly null enabled: is a no-op here (unlike the runlevels
        # branch above).
        if !enabled.nil? && enabled != runlevel_status["enabled"]?
          changed = true
          status_enabled["changed"] = JSON::Any.new(true)
        end

        if !check_mode && changed
          if enabled
            if updatercd = probe.bins["update-rc.d"]?
              run_command("#{updatercd} #{name} defaults")
            elsif chkconfig = probe.bins["chkconfig"]?
              run_command("#{chkconfig} #{name} on")
            end
          else
            if updatercd = probe.bins["update-rc.d"]?
              run_command("#{updatercd} #{name} disable")
            elsif chkconfig = probe.bins["chkconfig"]?
              run_command("#{chkconfig} #{name} off")
            end
          end
        end
      end

      # Snapshot the enable command's triple into the status dict, then
      # reset the trio - the state section's snapshot must not see it.
      if !check_mode && status_enabled["changed"].as_bool
        status_enabled["rc"] = JSON::Any.new(@rc.to_i64)
        status_enabled["stdout"] = JSON::Any.new(@out)
        status_enabled["stderr"] = JSON::Any.new(@err)
        @rc = 0
        @out = ""
        @err = ""

        if status_enabled["stderr"].as_s.includes?("illegal runlevel specified")
          # fail_json(msg, **result) mid-run: the result dict carries
          # name/changed/status, and status holds ONLY the enabled entry
          # (the state section's setdefault hasn't run yet).
          kwargs = {
            "name"    => JSON::Any.new(name),
            "changed" => JSON::Any.new(changed),
            "status"  => JSON::Any.new({"enabled" => JSON::Any.new(status_enabled)}),
          }
          kwargs["warnings"] = JSON.parse(@warnings.to_json) unless @warnings.empty?
          return fail_kwargs("Illegal runlevel specified for enable operation on service #{name}",
            ["msg", "name", "changed", "status", "failed"], kwargs)
        end
      end

      # ----------------------------------------------------------------
      # State - keyed by the RAW state string ('started', ...), or by
      # Python's None (JSON "null") when no state: was given - the
      # module's setdefault(module.params['state'], {}) runs before the
      # `if action:` gate, so the entry exists either way.
      # ----------------------------------------------------------------
      status_key = state || "null"
      status_state = status_entry

      if action_raw = state
        action = action_raw.downcase.sub(/p?ed$/, "")

        if action == "restart"
          changed = true
          status_state["changed"] = JSON::Any.new(true)
          unless check_mode
            # "cannot rely on existing 'restart' in init script" - always
            # a stop/start pair, sleeping between EACH runme (including
            # after the last one, as the module's loop does).
            {"stop", "start"}.each do |dothis|
              if failure = runme(script, arguments, daemonize, action, name, dothis)
                return failure
              end
              if sf = sleep_for
                sleep(sf.seconds) if sf > 0
              end
            end
          end
        elsif is_started != (action == "start")
          changed = true
          status_state["changed"] = JSON::Any.new(true)
          unless check_mode
            if failure = runme(script, arguments, daemonize, action, name, action)
              return failure
            end
          end
        elsif is_started == (action == "stop")
          changed = true
          status_state["changed"] = JSON::Any.new(true)
          unless check_mode
            if failure = runme(script, arguments, daemonize, action, name, action)
              return failure
            end
          end
        end

        if !check_mode && status_state["changed"].as_bool
          status_state["rc"] = JSON::Any.new(@rc.to_i64)
          status_state["stdout"] = JSON::Any.new(@out)
          status_state["stderr"] = JSON::Any.new(@err)
        end
      end

      result = PluginResult.new(
        changed: changed,
        failed: false,
        name: name,
        status: status_json(status_enabled, status_key, status_state),
        key_order: ["name", "changed", "status", "warnings"],
      )
      result.extra["warnings"] = JSON.parse(@warnings.to_json) unless @warnings.empty?
      result
    end

    # ------------------------------------------------------------------
    # Param decoding
    # ------------------------------------------------------------------

    # list elements=str: Ansible's check_type_str converts non-string
    # scalars through str() (int 3 -> "3", bool True -> "True"); the wire
    # carries a comma join (or a JSON array for a whole-span templated
    # list), with native members marked.
    private def parse_runlevels : Array(String)?
      return nil unless @params.has_key?("runlevels")
      return nil if explicit_null_param?("runlevels")

      if members = non_string_member_list("runlevels")
        return members.map { |member| runlevel_scalar_text(member.raw) }
      end

      raw = @params["runlevels"].to_s.strip
      return [] of String if raw.empty?
      if raw.starts_with?('[') && raw.ends_with?(']')
        parsed = Array(JSON::Any).from_json(raw) rescue nil
        return parsed.map { |member| runlevel_scalar_text(member.raw) } if parsed
      end
      raw.split(',').map(&.strip).reject(&.empty?)
    end

    # Ansible's check_type_str for a list ELEMENT: Python str() of the
    # native scalar (str(True) = 'True').
    private def runlevel_scalar_text(raw : JSON::Any::Type) : String
      case raw
      when String  then raw
      when Int64   then raw.to_s
      when Float64 then raw.to_s
      when Bool    then raw ? "True" : "False"
      else              ""
      end
    end

    private def json_string_array(values : Array(String)) : JSON::Any
      JSON::Any.new(values.map { |v| JSON::Any.new(v) })
    end

    # ------------------------------------------------------------------
    # Host probing
    # ------------------------------------------------------------------

    private record ProbeResult,
      script_exists : Bool,
      bins : Hash(String, String),
      rc_glob_count : Int32,
      runlevel_enabled : Hash(String, Int32)

    # One probe script replacing the module's os.path/glob/get_bin_path
    # reads. Binary search order mirrors get_bin_path(arg, opt_dirs=
    # ['/sbin','/usr/sbin','/bin','/usr/bin']): opt_dirs first, then
    # $PATH, then the sbin dirs it appends (/sbin, /usr/sbin,
    # /usr/local/sbin) - deduped, existence + executability checked.
    # The rc?.d globs run with the name unquoted in the pattern position,
    # exactly like Python's glob('/etc/rc?.d/S??%s' % name): glob
    # metacharacters in the name keep their wildcard meaning.
    private def probe_host(name : String, runlevels : Array(String)?) : ProbeResult
      script = name.starts_with?('/') ? name : "/etc/init.d/#{name}"
      quoted_script = shell_single_quote(script)
      quoted_name = shell_single_quote(name)

      rl_lines = (runlevels || [] of String).map do |runlevel|
        runlevel_quoted = shell_single_quote(runlevel)
        <<-SH
          count=0
          if [ -d /etc/rc0.d/ ]; then
            for f in /etc/rc#{runlevel_quoted}.d/S??$nm; do
              if [ -e "$f" ]; then count=$((count+1)); fi
            done
          else
            for f in /etc/init.d/rc#{runlevel_quoted}.d/S??$nm; do
              if [ -e "$f" ]; then count=$((count+1)); fi
            done
          end
          printf 'rl:%s=%s\\n' #{runlevel_quoted} "$count"
          SH
      end

      probe_script = <<-SH
        nm=#{quoted_name}
        sc=#{quoted_script}
        if [ -e "$sc" ]; then echo "script_exists=1"; else echo "script_exists=0"; fi
        for b in chkconfig update-rc.d insserv service; do
          found=""
          seen=" "
          for d in /sbin /usr/sbin /bin /usr/bin $(printf '%s' "$PATH" | tr ':' ' ') /sbin /usr/sbin /usr/local/sbin; do
            case "$seen" in *" $d "*) continue;; esac
            seen="$seen$d "
            if [ -x "$d/$b" ] && [ ! -d "$d/$b" ]; then found="$d/$b"; break; fi
          done
          printf 'bin:%s=%s\\n' "$b" "$found"
        done
        count=0
        for f in /etc/rc?.d/S??$nm; do
          if [ -e "$f" ]; then count=$((count+1)); fi
        done
        printf 'rcglob=%s\\n' "$count"
        #{rl_lines.join("\n")}
        SH

      output = remote_exec(probe_script)[:stdout].to_s

      script_exists = false
      rc_glob_count = 0
      bins = Hash(String, String).new
      runlevel_enabled = Hash(String, Int32).new

      output.each_line do |line|
        key, _, value = line.strip.partition('=')
        case key
        when "script_exists" then script_exists = value == "1"
        when "rcglob"        then rc_glob_count = value.to_i? || 0
        when .starts_with?("bin:")
          bins[key.lchop("bin:")] = value unless value.empty?
        when .starts_with?("rl:")
          runlevel_enabled[key.lchop("rl:")] = value.to_i? || 0
        end
      end

      ProbeResult.new(script_exists, bins, rc_glob_count, runlevel_enabled)
    end

    # get_ps: `ps auxww` output scanned for a substring, ps resolved
    # WITHOUT the module's opt_dirs (plain get_bin_path('ps', True)):
    # $PATH first, then the appended sbin dirs. A missing ps fails the
    # module with get_bin_path's own message - returned as a PluginResult
    # the caller bubbles up (a Bool means the scan ran).
    private def get_ps(needle : String) : Bool | PluginResult
      ps_path = find_ps_path
      if ps_path.nil?
        paths = (ENV["PATH"]?.to_s.split(':').reject(&.empty?) + %w[/sbin /usr/sbin /usr/local/sbin]).uniq
        # basic.py's ValueError through fail_json(required=True).
        return fail_plain(
          "Failed to find required executable \"ps\" in paths: #{paths.join(":")}")
      end

      result = remote_exec("#{ps_path} auxww")
      return false unless result[:exit_code] == 0

      result[:stdout].to_s.each_line do |line|
        return true if line.includes?(needle)
      end
      false
    end

    # Same search order as the probe's bins, minus the module's opt_dirs.
    private def find_ps_path : String?
      script = <<-SH
        found=""
        seen=" "
        for d in $(printf '%s' "$PATH" | tr ':' ' ') /sbin /usr/sbin /usr/local/sbin; do
          case "$seen" in *" $d "*) continue;; esac
          seen="$seen$d "
          if [ -x "$d/ps" ] && [ ! -d "$d/ps" ]; then found="$d/ps"; break; fi
        done
        printf '%s' "$found"
        SH
      output = remote_exec(script)[:stdout].to_s
      output.empty? ? nil : output
    end

    # ------------------------------------------------------------------
    # Command plumbing
    # ------------------------------------------------------------------

    private def run_command(cmd : String) : Nil
      result = remote_exec(cmd)
      @rc = result[:exit_code]
      @out = result[:stdout].to_s
      @err = result[:stderr].to_s
    end

    # module_utils daemonize(module, cmd): forks a helper that runs the
    # command detached, ships the (rc, stdout, stderr) triple back over a
    # pipe and exits. The observable module result is exactly a
    # synchronous run_command of the same string (the pickled triple
    # round-trips unchanged), so this replays it through #remote_exec -
    # the init script sees the same command line either way, and the
    # fork/setsid plumbing itself has no observable module output.
    private def daemonize_run(cmd : String) : Nil
      run_command(cmd)
    end

    # The module's runme closure: runs the init script verb, fails the
    # module on a non-zero rc with the (rc, stdout, stderr) kwargs.
    private def runme(script : String, arguments : String?, daemonize : Bool, action : String, name : String, doit : String) : PluginResult?
      cmd = "#{script} #{doit} #{arguments.nil? ? "" : arguments}"
      if daemonize
        daemonize_run(cmd)
      else
        run_command(cmd)
      end
      return nil if @rc == 0

      kwargs = {
        "rc"     => JSON::Any.new(@rc.to_i64),
        "stdout" => JSON::Any.new(@out),
        "stderr" => JSON::Any.new(@err),
      }
      kwargs["warnings"] = JSON.parse(@warnings.to_json) unless @warnings.empty?
      fail_kwargs("Failed to #{action} service: #{name}",
        ["rc", "stdout", "stderr", "failed", "msg",
         "stdout_lines", "stderr_lines", "changed", "exception"], kwargs)
    end

    # ------------------------------------------------------------------
    # Result shapes
    # ------------------------------------------------------------------

    # A fresh status dict in the module's own key order.
    private def status_entry : Hash(String, JSON::Any)
      entry = Hash(String, JSON::Any).new
      entry["changed"] = JSON::Any.new(false)
      entry["rc"] = JSON::Any.new(nil)
      entry["stdout"] = JSON::Any.new(nil)
      entry["stderr"] = JSON::Any.new(nil)
      entry
    end

    # result['status']: {'enabled'} first, then the state key - 'null'
    # included, JSON-encoding Python's None key (live-verified vs
    # 2.19.11: a stateless enabled:-only task registers
    # status: {"enabled": {...}, "null": {...}}).
    private def status_json(enabled_entry : Hash(String, JSON::Any), state_key : String, state_entry : Hash(String, JSON::Any)) : JSON::Any
      outer = Hash(String, JSON::Any).new
      outer["enabled"] = JSON::Any.new(enabled_entry)
      outer[state_key] = JSON::Any.new(state_entry)
      JSON::Any.new(outer)
    end

    private def fail_plain(msg : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: msg)
    end

    # fail_json(**kwargs)-shaped failures: the module's own dict rides
    # the failure result (name/changed/status for the illegal-runlevel
    # case, rc/stdout/stderr for the runme failure), keyed in the
    # kwargs-first order real's registered shape carries (see
    # apache2_module's key_order comment for the same live-verified
    # ordering).
    private def fail_kwargs(msg : String, key_order : Array(String), kwargs : Hash(String, JSON::Any)) : PluginResult
      result = PluginResult.new(changed: false, failed: true, msg: msg, key_order: key_order)
      kwargs.each { |key, value| result.extra[key] = value }
      result
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::SysvinitPlugin.new(config)
plugin.run
