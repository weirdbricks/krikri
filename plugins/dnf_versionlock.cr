#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
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
  class DnfVersionlockPlugin < BasePlugin
    DNF_BIN          = "/usr/bin/dnf"
    VERSIONLOCK_CONF = "/etc/dnf/plugins/versionlock.conf"
    NEVRA_RE         = /^(?<name>.+)-(?<epoch>\d+):(?<version>.+)-(?<release>[^.]+)\.(?<arch>[^.]+)$/

    def execute : PluginResult
      precondition_error = check_preconditions
      return precondition_error if precondition_error

      patterns = parse_names
      raw = is_true?(@params["raw"]?)
      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)

      param_error = validate_state_params(state, patterns)
      return param_error if param_error

      locklist_pre = get_package_list

      specs_toadd, specs_todelete, msg = case state
                                         when "present", "excluded"
                                           add_or_exclude(state, patterns, locklist_pre, raw, check_mode)
                                         when "absent"
                                           remove(patterns, locklist_pre, raw, check_mode)
                                         when "clean"
                                           clean(locklist_pre, raw, check_mode)
                                         else
                                           return PluginResult.new(changed: false, failed: true, msg: "state must be one of present/excluded/absent/clean, got '#{state}'")
                                         end

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

    private def check_preconditions : PluginResult?
      unless File.exists?(DNF_BIN)
        return PluginResult.new(changed: false, failed: true, msg: "Failed to find required executable \"dnf\"")
      end
      unless File.exists?(VERSIONLOCK_CONF)
        return PluginResult.new(changed: false, failed: true, msg: "plugin versionlock is required")
      end
      nil
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
        next unless m
        evr = "#{m["epoch"]}:#{m["version"]}-#{m["release"]}"
        (result[m["name"]] ||= Set(String).new) << evr
      end

      result
    end

    private def get_package_list : Array(String)
      do_versionlock("list").split
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
      Process.run(DNF_BIN, args, output: output, error: Process::Redirect::Close)
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

      begin
        list = Array(String).from_json(raw.gsub('\'', '"'))
        return list unless list.empty?
      rescue
      end

      return [] of String if raw.empty?
      raw.includes?(",") ? raw.split(",").map(&.strip) : [raw]
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::DnfVersionlockPlugin.new(config)
plugin.run
