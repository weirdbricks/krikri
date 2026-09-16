#!/usr/bin/env crystal

# timezone module (community.general.timezone) - sets the system timezone.
#
# Real community.general.timezone's AnsibleModule surface (argument_spec:
# hwclock type=str choices local/UTC alias rtc, name type=str;
# required_one_of hwclock/name): choices first, then required_one_of
# ("one of the following is required: hwclock, name"), then unsupported
# params - all in module init, before Timezone.__new__ picks a backend.
#
# Backend selection reproduces Timezone.__new__ on Linux: probe
# `timedatectl` (get_bin_path + run rc==0); usable -> SystemdTimezone
# (`timedatectl status` scrape / `timedatectl set-timezone` /
# `set-local-rtc`), otherwise NosystemdTimezone. The nosystemd backend is
# what the podman-diff harness containers (bookworm-slim, no systemd)
# actually exercise: edit /etc/timezone's first matching line (deleting
# extras), `ln -sf` the zoneinfo file over /etc/localtime,
# `dpkg-reconfigure --frontend noninteractive tzdata` on Debian
# (dpkg-reconfigure present), else the RHEL/SUSE /etc/sysconfig/clock
# branch with `tzdata-update` when available and /etc/localtime not a
# symlink (the SuSE TIMEZONE= line-shape detection is not reproduced -
# no benchmarked target runs SUSE). hwclock edits /etc/default/rcS
# (Debian) or /etc/sysconfig/clock (RHEL) and runs
# `hwclock --systohc --utc|--localtime`.
#
# Both backends verify the planned zone exists as
# /usr/share/zoneinfo/<name> at init, failing with real's wrapped abort
# format ("Error message:" / "Other message(s):" lines), and `changed` is
# real's own before!=after comparison of EVERY planned key - so a name
# that was already current reports changed: false and no command runs at
# all (real skips the change in that case entirely).

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/get_bin_path"

module Krikri
  class TimezonePlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Real community.general.timezone's argument_spec, insertion order.
    SPEC = {
      "hwclock" => %w[rtc],
      "name"    => %w[],
    }

    HWCLOCK_CHOICES = %w[local UTC]
    EXTRA_BIN_DIRS  = %w[/sbin /usr/sbin /bin /usr/bin]

    # Raised by #run_checked when a backend command exits non-zero,
    # carrying the fail_json msg real run_command(check_rc=True) hands
    # the module (stderr, falling back to stdout).
    class TimezoneCommandFailure < Exception
    end

    @check_mode : Bool
    @msg = [] of String
    @bins = Hash(String, String).new
    @searched_paths = ""
    @name_conf = "/etc/timezone"
    @hwclock_conf = "/etc/default/rcS"
    @name_regex = /^([^\s]+)/
    @name_format = "%s\n"
    @debian = true

    def initialize(config : JSON::Any)
      super(config)
      @check_mode = true?(@params["_ansible_check_mode"]?)
      if (rtc = @params["rtc"]?) && !@params.has_key?("hwclock")
        @params["hwclock"] = rtc
      end
    end

    def execute : PluginResult
      if error = validate_params
        return error
      end

      # planned: only params actually passed (real __init__ skips None
      # values), in argument_spec insertion order.
      planned = {} of String => String
      if hwclock = @params["hwclock"]?
        planned["hwclock"] = hwclock
      end
      if name = @params["name"]?
        planned["name"] = name
      end

      systemd_backend = pick_backend
      init_nosystemd_paths unless systemd_backend

      # Backend init: NosystemdTimezone requires hwclock's binary ONLY
      # when hwclock is planned (required="hwclock" in self.value). Both
      # backends verify the planned zone file BEFORE checking any
      # current state.
      resolve_binaries
      if !systemd_backend && planned.has_key?("hwclock") && @bins["hwclock"].empty?
        return fail(PluginHelpers::GetBinPath.missing_executable_error("hwclock", @searched_paths))
      end
      if planned.has_key?("name") && (error = verify_timezone(planned["name"]))
        return error
      end

      before = planned.keys.to_h { |key| {key, get_value(key, systemd_backend, planned[key])} }

      if @check_mode
        after = planned.dup
      else
        begin
          planned.each do |key, value|
            set_value(key, value, systemd_backend) if before[key] != value
          end
        rescue e : TimezoneCommandFailure
          return PluginResult.new(changed: false, failed: true, msg: e.message.to_s)
        end
        after = planned.keys.to_h { |key| {key, get_value(key, systemd_backend, planned[key])} }
        if after != planned
          return fail("still not desired state, though changes have made - planned: #{planned}, after: #{after}")
        end
      end

      changed = before != after
      PluginResult.new(
        changed: changed,
        failed: false,
        msg: @msg.empty? ? "" : @msg.join("\n"),
        diff: generate_attribute_diff(before, after),
      )
    end

    private def validate_params : PluginResult?
      SPEC.each do |param, _aliases|
        raw = @params[param]?
        next unless raw
        if param == "hwclock" && !HWCLOCK_CHOICES.includes?(raw)
          return choices_error("hwclock", HWCLOCK_CHOICES, raw)
        end
      end

      unless @params.has_key?("hwclock") || @params.has_key?("name")
        return PluginResult.new(changed: false, failed: true,
          msg: "one of the following is required: hwclock, name")
      end

      if unsupported = unsupported_param_keys(@params, SPEC)
        unless unsupported.empty?
          return unsupported_params_error("community.general.timezone", unsupported, SPEC)
        end
      end

      nil
    end

    # Real abort(): fail_json with the error wrapped under an
    # "Error message:" header, appending everything the backend already
    # logged under "Other message(s):".
    private def fail(error_msg : String) : PluginResult
      lines = ["Error message:", error_msg]
      unless @msg.empty?
        lines << "Other message(s):"
        lines.concat(@msg)
      end
      PluginResult.new(changed: false, failed: true, msg: lines.join("\n"))
    end

    # Timezone.__new__ on Linux: timedatectl found AND usable -> systemd.
    # The usability probe is run_command WITHOUT check_rc (a failing
    # timedatectl just means "not usable").
    private def pick_backend : Bool
      resolve_binaries
      return false if @bins["timedatectl"].empty?
      remote_exec("#{@bins["timedatectl"]}")[:exit_code] == 0
    end

    # Real NosystemdTimezone.__init__'s distribution wiring (Debian vs
    # RHEL/SUSE): which config file holds the zone, which line regex
    # matches it, and its line format.
    private def init_nosystemd_paths : Nil
      @debian = !@bins["dpkg-reconfigure"].empty?
      if @debian
        @name_conf = "/etc/timezone"
        @hwclock_conf = "/etc/default/rcS"
        @name_regex = /^([^\s]+)/
        @name_format = "%s\n"
      else
        @name_conf = "/etc/sysconfig/clock"
        @hwclock_conf = "/etc/sysconfig/clock"
        @name_regex = /^ZONE\s*=\s*"?([^"\s]+)"?/
        @name_format = "ZONE=\"%s\"\n"
      end
    end

    # _verify_timezone: the planned zone must exist as a zoneinfo FILE.
    private def verify_timezone(tz : String) : PluginResult?
      tzfile = "/usr/share/zoneinfo/#{tz}"
      rc = remote_exec("[ -f '#{tzfile}' ] && echo y || echo n")
      if rc[:stdout].to_s.strip == "n"
        return fail(%(given timezone "#{tz}" is not available))
      end
      nil
    end

    # Real SystemdTimezone.get: scrape `timedatectl status` (cached per
    # phase there; the values can't change mid-task here). A status line
    # that matches neither regexp would be real's own uncaught
    # AttributeError - can't be reproduced with a sane failure, the
    # scrape simply yields "".
    private def get_value(key : String, systemd_backend : Bool, planned_value : String) : String
      if systemd_backend
        status = remote_exec("#{@bins["timedatectl"]} status")[:stdout].to_s
        if key == "name"
          status.match(/^\s*Time ?zone\s*:\s*(\S+)/m).try(&.[1]) || ""
        else
          status.match(/^\s*RTC in local TZ\s*:\s*(\S+)/m).try(&.[1]) == "yes" ? "local" : "UTC"
        end
      elsif key == "name"
        get_name_from_config(planned_value)
      else
        get_hwclock_from_config(planned_value)
      end
    end

    # Real NosystemdTimezone.get(key="name"): read the config file, then
    # when it already matches the planned value, cross-check whatever
    # /etc/localtime actually points at (or its content when not a
    # symlink) - a stale symlink pointing elsewhere reports THAT zone
    # instead, and anything unresolvable reports "n/a".
    private def get_name_from_config(planned : String) : String
      content = read_config(@name_conf)
      return "n/a" if content.nil?
      value = content.match(@name_regex).try(&.[1])
      return "n/a" unless value
      return value unless value == planned

      out = remote_exec(<<-SH)[:stdout].to_s.strip
      if [ -L /etc/localtime ]; then
        if [ -e /etc/localtime ]; then
          readlink /etc/localtime
        else
          echo __BROKEN__
        fi
      else
        echo __NOTLINK__
      fi
      SH
      return "n/a" if out == "__BROKEN__"
      if out == "__NOTLINK__"
        cmp = remote_exec("cmp -s /etc/localtime /usr/share/zoneinfo/#{planned} && echo same || echo diff")
        return cmp[:stdout].to_s.strip == "same" ? value : "n/a"
      end
      if link_tz = out.match(/(?:\/(?:usr\/share|etc)\/zoneinfo\/)(.+)/m).try(&.[1])
        return link_tz == planned ? value : link_tz
      end
      "n/a"
    end

    # Real NosystemdTimezone.get(key="hwclock"): UTC= in the hwclock
    # config file (yes->UTC, no->local), falling back to /etc/adjtime's
    # UTC/LOCAL line only when the config already matches the planned
    # value. Missing config reads "n/a"; missing adjtime defaults UTC.
    private def get_hwclock_from_config(planned : String) : String
      content = read_config(@hwclock_conf)
      value = nil
      if content
        if utc = content.match(/^UTC\s*=\s*(\S+)/m).try(&.[1])
          value = (utc == "yes") ? "UTC" : "local"
        end
      end
      return "n/a" unless value
      return value unless value == planned

      adj = read_config("/etc/adjtime")
      return "UTC" if adj.nil?
      if utc = adj.match(/^(UTC|LOCAL)$/m).try(&.[1])
        utc == "UTC" ? "UTC" : "local"
      else
        "UTC"
      end
    end

    private def set_value(key : String, value : String, systemd_backend : Bool) : Nil
      if systemd_backend
        subcmd = key == "name" ? "set-timezone" : "set-local-rtc"
        arg = key == "hwclock" ? (value == "local" ? "yes" : "no") : value
        run_checked("#{@bins["timedatectl"]} #{subcmd} #{arg}", log: true)
      elsif key == "name"
        set_timezone_nosystemd(value)
      else
        set_hwclock_nosystemd(value)
      end
    end

    # Real NosystemdTimezone.set_timezone: edit the config file's first
    # matched line (deleting extras), then the backend's update commands
    # - Debian: ln -sf + dpkg-reconfigure; else ln -sf (or cp
    # --remove-destination, the branch's default) + tzdata-update when
    # /etc/localtime is NOT a symlink.
    private def set_timezone_nosystemd(value : String) : Nil
      new_line = @name_format.gsub("%s", value)
      deleted = edit_config_file(@name_conf, @name_regex, new_line)
      @msg << "Added 1 line and deleted #{deleted} line(s) on #{@name_conf}"

      tzfile = "/usr/share/zoneinfo/#{value}"
      if @debian
        remote_exec("ln -sf '#{tzfile}' /etc/localtime")
        remote_exec("#{@bins["dpkg-reconfigure"]} --frontend noninteractive tzdata")
      else
        is_link = remote_exec("[ -L /etc/localtime ] && echo y || echo n")[:stdout].to_s.strip == "y"
        if is_link
          remote_exec("cp --remove-destination '#{tzfile}' /etc/localtime")
        elsif !@bins["tzdata-update"].empty?
          remote_exec("#{@bins["tzdata-update"]}")
        end
      end
    end

    private def set_hwclock_nosystemd(value : String) : Nil
      utc = value == "local" ? "no" : "yes"
      option = value == "local" ? "--localtime" : "--utc"
      # The hwclock config file may not exist yet (real's allow_no_file
      # treats ENOENT as an empty file and creates it); the edit always
      # runs on this branch.
      deleted = edit_config_file(@hwclock_conf, /^UTC\s*=/, "UTC=#{utc}\n")
      @msg << "Added 1 line and deleted #{deleted} line(s) on #{@hwclock_conf}"
      # real logs the hwclock invocation (execute log=True) AND fails the
      # module through check_rc when it exits non-zero - in a container
      # without an accessible RTC, "hwclock: Cannot access the Hardware
      # Clock" fails the task even though the rcS edit landed.
      @msg << "executed `#{@bins["hwclock"]} --systohc #{option}`"
      run_checked("#{@bins["hwclock"]} --systohc #{option}")
    end

    # Real _edit_file: replace the FIRST matched line, delete any other
    # matches, insert at the first match's index (0 when nothing
    # matched), report "Added 1 line and deleted N line(s)".
    private def edit_config_file(path : String, pattern : Regex, new_line : String) : Int32
      lines = (read_config(path) || "").lines
      matched = lines.each_index.select { |i| lines[i] =~ pattern }.to_a
      insert_at = matched.first? || 0
      matched.reverse_each { |i| lines.delete_at(i) }
      lines.insert(insert_at, new_line.chomp)
      File.write(path, lines.map { |l| "#{l}\n" }.join)
      matched.size
    end

    # ENOENT reads as missing content (real's allow_no_file); any other
    # OSError would abort with real's "could not read configuration
    # file" wording - not reproduced, the plugin runs as root wherever
    # the module would.
    private def read_config(path : String) : String?
      File.exists?(path) ? File.read(path) : nil
    end

    # Real execute(*commands): run_command(check_rc=True), failing the
    # module the moment anything exits non-zero. Only callers with
    # log=True append to the msg list (set-timezone / set-local-rtc /
    # hwclock --systohc; the ln/cp/dpkg-reconfigure/tzdata-update
    # commands are NOT logged by real).
    private def run_checked(cmd : String, log : Bool = false) : Nil
      result = remote_exec(cmd)
      @msg << "executed `#{cmd}`" if log
      if result[:exit_code] != 0
        err = result[:stderr].to_s
        out = result[:stdout].to_s
        raise TimezoneCommandFailure.new(!err.strip.empty? ? err : out)
      end
    end

    private def resolve_binaries : Nil
      script = <<-SH
      for name in timedatectl cp hwclock dpkg-reconfigure ln tzdata-update; do
        found=""
        for d in $(printf '%s' "$PATH" | tr ':' ' ') #{EXTRA_BIN_DIRS.join(' ')}; do
          if [ -z "$found" ] && [ -x "$d/$name" ]; then found="$d/$name"; fi
        done
        printf 'bin:%s=%s\\n' "$name" "$found"
      done
      searched=""
      for d in $(printf '%s' "$PATH" | tr ':' ' ') #{EXTRA_BIN_DIRS.join(' ')}; do
        case ":$searched:" in *":$d:"*) ;; *) searched="${searched:+$searched:}$d" ;; esac
      done
      printf 'searched=%s\\n' "$searched"
      SH

      remote_exec(script)[:stdout].to_s.each_line do |line|
        key, _, value = line.strip.partition('=')
        if key.starts_with?("bin:")
          @bins[key.lchop("bin:")] = value
        elsif key == "searched"
          @searched_paths = value
        end
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::TimezonePlugin.new(config)
plugin.run
