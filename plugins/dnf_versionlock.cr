#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # dnf_versionlock plugin - locks/excludes/unlocks package versions via
  # the `dnf versionlock` plugin. Compatible with (a subset of) Ansible's
  # community.general.dnf_versionlock module. dnf5 is not supported (same
  # as upstream's own documented limitation).
  #
  # Parameters:
  #   name: list (or comma-separated string) of package name specs
  #   raw: bool (default false) - use name: patterns verbatim instead of
  #     resolving to NEVRAs via `dnf repoquery`
  #   state: present (default) / excluded / absent / clean
  class DnfVersionlockError < Exception
  end

  class DnfVersionlockPlugin < BasePlugin
    DNF_BIN          = "/usr/bin/dnf"
    VERSIONLOCK_CONF = "/etc/dnf/plugins/versionlock.conf"
    # Release and arch are both greedy (.+, not [^.]+): Fedora-family
    # releases contain dots themselves (e.g. "1.fc41"), so only the final
    # dot separates release from arch - same pattern as the upstream
    # module's own NEVRA_RE.
    NEVRA_RE = /^(?<name>.+)-(?<epoch>\d+):(?<version>.+)-(?<release>.+)\.(?<arch>.+)$/

    def execute : PluginResult
      # AnsibleModule's constructor validates state's choices BEFORE
      # main() resolves the dnf binary or runs any semantic option
      # check - so an invalid state fails with the choices message even
      # on a host without dnf (real order: arg-spec validation ->
      # get_bin_path("dnf", required) -> versionlock conf -> option
      # checks).
      state = @params["state"]? || "present"
      unless ["present", "absent", "excluded", "clean"].includes?(state)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: present, absent, excluded, clean, got: #{state}")
      end

      precondition_error = check_preconditions
      return precondition_error if precondition_error

      patterns = parse_names
      raw = true?(@params["raw"]?)
      check_mode = true?(@params["check_mode"]?)

      param_error = validate_state_params(state, patterns)
      return param_error if param_error

      locklist_pre = get_package_list
      result = apply_state(state, patterns, locklist_pre, raw, check_mode)
      return result if result.is_a?(PluginResult)
      specs_toadd, specs_todelete, msg = result

      changed = !specs_toadd.empty? || !specs_todelete.empty?
      locklist_post = if check_mode
                        state == "clean" ? [] of String : locklist_pre
                      else
                        get_package_list
                      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: msg,
        locklist_pre: locklist_pre,
        locklist_post: locklist_post,
        specs_toadd: specs_toadd,
        specs_todelete: specs_todelete,
      )
    end

    private def apply_state(state : String, patterns : Array(String), locklist_pre : Array(String),
                            raw : Bool, check_mode : Bool) : {Array(String), Array(String), String} | PluginResult
      case state
      when "present", "excluded"
        add_or_exclude(state, patterns, locklist_pre, raw, check_mode)
      when "absent"
        remove(patterns, locklist_pre, raw, check_mode)
      when "clean"
        clean(locklist_pre, raw, check_mode)
      else
        PluginResult.new(changed: false, failed: true, msg: "state must be one of present/excluded/absent/clean, got '#{state}'")
      end
    rescue e : DnfVersionlockError
      PluginResult.new(changed: false, failed: true, msg: e.message || "dnf versionlock command failed")
    end

    private def check_preconditions : PluginResult?
      unless File.exists?(DNF_BIN)
        return PluginResult.new(changed: false, failed: true, msg: "Failed to find required executable \"dnf\"")
      end
      # dnf5 keeps its locklist elsewhere and never reads the dnf4 plugin
      # config, so the missing-conf failure only applies to dnf4 hosts
      # (same gate as upstream's own main()).
      if !dnf5? && !File.exists?(VERSIONLOCK_CONF)
        return PluginResult.new(changed: false, failed: true, msg: "plugin versionlock is required")
      end
      nil
    end

    private def dnf5? : Bool
      File.realpath(DNF_BIN) == "/usr/bin/dnf5"
    end

    private def validate_state_params(state : String, patterns : Array(String)) : PluginResult?
      if state == "clean" && !patterns.empty?
        return PluginResult.new(changed: false, failed: true, msg: "clean state is incompatible with a name list")
      end
      if state != "clean" && patterns.empty?
        return PluginResult.new(changed: false, failed: true, msg: "name list is required for #{state} state")
      end
      nil
    end

    private def add_or_exclude(state : String, patterns : Array(String), locklist_pre : Array(String), raw : Bool, check_mode : Bool) : {Array(String), Array(String), String}
      specs_toadd = [] of String

      if raw
        patterns.each do |pattern|
          entry = state == "present" ? pattern : "!#{pattern}"
          specs_toadd << pattern unless locklist_pre.includes?(entry)
        end
      else
        available = get_packages(patterns, only_installed: false)
        installed = get_packages(patterns, only_installed: true)
        installed.each { |name, evrs| available[name] = evrs }

        available.each do |name, evrs|
          evrs.each do |evr|
            locklist_entry = "#{name}-#{evr}.*"
            entry = state == "present" ? locklist_entry : "!#{locklist_entry}"
            specs_toadd << locklist_entry unless locklist_pre.includes?(entry)
          end
        end
      end

      msg = ""
      if !specs_toadd.empty? && !check_mode
        cmd = state == "present" ? "add" : "exclude"
        msg = do_versionlock(cmd, specs_toadd, raw)
      end

      {specs_toadd, [] of String, msg}
    end

    private def remove(patterns : Array(String), locklist_pre : Array(String), raw : Bool, check_mode : Bool) : {Array(String), Array(String), String}
      specs_todelete = [] of String

      if raw
        patterns.each { |pattern| specs_todelete << pattern if locklist_pre.includes?(pattern) }
      else
        patterns.each do |pattern|
          locklist_pre.each { |entry| specs_todelete << pattern if nevra_match(entry, pattern) }
        end
      end

      msg = ""
      msg = do_versionlock("delete", specs_todelete, raw) if !specs_todelete.empty? && !check_mode

      {[] of String, specs_todelete, msg}
    end

    private def clean(locklist_pre : Array(String), raw : Bool, check_mode : Bool) : {Array(String), Array(String), String}
      specs_todelete = locklist_pre
      msg = ""
      msg = do_versionlock("clear", nil, raw) if !specs_todelete.empty? && !check_mode

      {[] of String, specs_todelete, msg}
    end

    # Matches versionlock's own C(_match) - a locklist entry (its leading
    # `!` stripped) matches a pattern either verbatim or via any of the
    # NEVRA-derived name/name.arch/name-version/etc. shorthands, each
    # checked with fnmatch-style globbing (so a pattern like "bash-0:4.*"
    # matches "bash-0:4.4.20-1.el8_4.*").
    private def nevra_match(entry : String, pattern : String) : Bool
      entry = entry.lstrip('!')
      return true if entry == pattern

      m = NEVRA_RE.match(entry)
      return false unless m

      name = m["name"]
      epoch = m["epoch"]
      version = m["version"]
      release = m["release"]
      arch = m["arch"]

      candidates = [
        name,
        "#{name}.#{arch}",
        "#{name}-#{version}",
        "#{name}-#{version}-#{release}",
        "#{name}-#{epoch}:#{version}",
        "#{name}-#{version}-#{release}.#{arch}",
        "#{name}-#{epoch}:#{version}-#{release}",
        "#{epoch}:#{name}-#{version}-#{release}.#{arch}",
        "#{name}-#{epoch}:#{version}-#{release}.#{arch}",
      ]

      candidates.any? { |candidate| File.match?(pattern, candidate) }
    end

    private def get_packages(patterns : Array(String), only_installed : Bool) : Hash(String, Set(String))
      result = Hash(String, Set(String)).new
      args = ["-q", "repoquery"] + (only_installed ? ["--installed"] : [] of String) + patterns
      out = run_dnf_bin(args)

      out.split.each do |pkg|
        m = NEVRA_RE.match(pkg)
        raise DnfVersionlockError.new("failed to parse nevra for #{pkg}") unless m
        evr = "#{m["epoch"]}:#{m["version"]}-#{m["release"]}"
        (result[m["name"]] ||= Set(String).new) << evr
      end

      result
    end

    private def get_package_list : Array(String)
      output = run_dnf_bin(["-q", "versionlock", "list"])
      return output.split if !dnf5?

      # dnf5's `versionlock list` prints TOML stanzas ("Package name:",
      # "evr = ..." pairs with leading comment/blank lines) instead of dnf4's
      # one-entry-per-line locklist - re-resolve each stanza's name through
      # repoquery to rebuild dnf4-style "name-evr.*" entries, same as the
      # upstream module's own dnf5 branch.
      package_list = [] of String
      stanza_start = false
      package_name = ""

      output.each_line do |line|
        next if line.starts_with?('#') || line.starts_with?(' ')
        if line.starts_with?("Package name:")
          stanza_start = true
          name = line.split(':', 2)[1].strip
          pkg_name = get_packages([name], only_installed: false)
          package_name = "#{name}-#{pkg_name[name].first}.*"
          package_list << package_name unless package_list.includes?(package_name)
        end
        if line.starts_with?("evr") && stanza_start
          package_list << package_name unless package_list.includes?(package_name)
          stanza_start = false
        end
      end

      package_list
    end

    private def do_versionlock(command : String, patterns : Array(String)? = nil, raw : Bool = false) : String
      raw_flag = raw ? ["--raw"] : [] of String

      if patterns && !patterns.empty?
        patterns.map { |pattern| run_dnf_bin(["-q", "versionlock", command] + raw_flag + [pattern]) }.join("\n")
      else
        run_dnf_bin(["-q", "versionlock", command])
      end
    end

    private def run_dnf_bin(args : Array(String)) : String
      output = IO::Memory.new
      errout = IO::Memory.new
      rc = Process.run(DNF_BIN, args, output: output, error: errout).exit_code
      unless rc == 0
        raise DnfVersionlockError.new("Command '#{DNF_BIN} #{args.join(" ")}' failed with rc #{rc}: #{errout}#{output}".strip)
      end
      output.to_s
    end

    private def parse_names : Array(String)
      raw = @params["name"]?
      return [] of String unless raw

      begin
        parsed = JSON.parse(raw)
        return parsed.as_a.map(&.as_s) if parsed.as_a?
        return [parsed.as_s] if parsed.as_s? && !parsed.as_s.empty?
      rescue
      end

      # ONLY valid JSON - never a Python-repr repair pass: a value that
      # merely LOOKS like a container is a plain STRING in real
      # ansible-core (live-verified vs ansible-playbook 2.19.11, see
      # apt.cr's parse_package_names). A whole-value `{{ list_var }}`
      # container arg arrives as the double-quoted JSON the wire
      # serialized it to (see substitute_task_params's whole-single-span
      # comment), which the JSON.parse above already handles.

      return [] of String if raw.empty?
      raw.includes?(",") ? raw.split(",").map(&.strip) : [raw]
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::DnfVersionlockPlugin.new(config)
plugin.run
