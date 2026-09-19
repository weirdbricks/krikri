#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # yum_versionlock plugin - locks/unlocks package versions via the
  # `yum versionlock` plugin (the yum-plugin-versionlock package).
  # Compatible with Ansible's community.general.yum_versionlock module
  # (community/general/plugins/modules/yum_versionlock.py), which is
  # deliberately simpler than its dnf_versionlock sibling: no NEVRA
  # resolution through repoquery, no raw:/excluded:/clean - just
  # add/delete on the yum locklist.
  #
  # Parameters:
  #   name: list (or comma-separated string) of package name specs
  #   state: present (default) / absent
  class YumVersionlockError < Exception
  end

  class YumVersionlockPlugin < BasePlugin
    YUM_BIN = "/usr/bin/yum"

    # The real module matches each locklist entry against two NEVRA
    # shapes - yum's epoch-prefixed "1:name-version-release.arch" first,
    # then dnf's "name-1:version-release.arch" (on DNF-based distros yum
    # is a symlink to dnf, whose versionlock writes the other order).
    # Release and arch are both greedy (.+, not [^.]+): Fedora-family
    # releases contain dots themselves, so only the final dot separates
    # release from arch - same pattern as the upstream module's own
    # NEVRA_RE_YUM/NEVRA_RE_DNF.
    NEVRA_RE_YUM = /^(?<exclude>!)?(?<epoch>\d+):(?<name>.+)-(?<version>.+)-(?<release>.+)\.(?<arch>.+)$/
    NEVRA_RE_DNF = /^(?<exclude>!)?(?<name>.+)-(?<epoch>\d+):(?<version>.+)-(?<release>.+)\.(?<arch>.+)$/

    def execute : PluginResult
      # Real AnsibleModule validates required/choices at construction,
      # BEFORE the module resolves the yum binary or runs any command -
      # so an invalid invocation fails with the argument-spec message
      # even on a host without yum (real order: arg-spec validation ->
      # get_bin_path("yum", required) -> `yum versionlock list`).
      unless @params["name"]?
        return PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: name")
      end

      state = @params["state"]? || "present"
      unless ["present", "absent"].includes?(state)
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: present, absent, got: #{state}")
      end

      precondition_error = check_preconditions
      return precondition_error if precondition_error

      packages = parse_names
      check_mode = true?(@params["_ansible_check_mode"]?)

      locklist = get_versionlock_packages

      # The real module only shells out for the specs that would actually
      # change the locklist - under `present` a spec any locklist entry
      # already matches is skipped, under `absent` only matched specs go
      # to `yum versionlock delete`. Matching happens against the raw
      # `yum versionlock list` output split on whitespace; non-NEVRA
      # tokens (banner lines etc.) simply never match.
      packages_list = packages.select do |single_pkg|
        matched = locklist.any? { |entry| entry_matches(entry, single_pkg) }
        state == "present" ? !matched : matched
      end

      changed = !packages_list.empty?
      ensure_state(packages_list, state == "present" ? "add" : "delete") if changed && !check_mode

      # Real module exit: exit_json(changed=changed, meta={"packages":
      # packages, "state": state}) - the REQUESTED specs (not just the
      # changed ones) and the resolved state come back under a top-level
      # "meta" key. (The module's own RETURN docs claim a top-level
      # "packages"; the code is the behavior that matters.)
      PluginResult.new(changed: changed, failed: false,
        meta: {"packages" => packages, "state" => state})
    rescue e : YumVersionlockError
      PluginResult.new(changed: false, failed: true, msg: e.message || "yum versionlock command failed")
    end

    private def check_preconditions : PluginResult?
      unless File.exists?(YUM_BIN)
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to find required executable \"yum\" in paths: #{ENV.fetch("PATH", "")}")
      end
      nil
    end

    # Mirrors the real module's C(get_versionlock_packages): rc 0 returns
    # stdout; the yum-plugin-versionlock-not-installed case is rc 1 with
    # "No such command:" on stderr (upstream's match is the mid-word
    # "o such command:" - kept verbatim); anything else fails with
    # stderr + stdout concatenated, no separator.
    private def get_versionlock_packages : Array(String)
      result = run_yum(["versionlock", "list"])
      return result[:output].split if result[:rc] == 0
      if result[:rc] == 1 && result[:errout].includes?("o such command:")
        raise YumVersionlockError.new("Error: Please install rpm package yum-plugin-versionlock : #{result[:errout]}#{result[:output]}")
      end
      raise YumVersionlockError.new("Error: #{result[:errout]}#{result[:output]}")
    end

    # Mirrors the real module's C(ensure_state): one `-q` invocation for
    # all specs; stdout carrying "No package found for" fails even with
    # rc 0 - yum reports a spec it could not resolve that way and exits
    # successfully (checked BEFORE the rc, as upstream does).
    private def ensure_state(packages_list : Array(String), command : String) : Nil
      result = run_yum(["-q", "versionlock", command] + packages_list)
      raise YumVersionlockError.new(result[:output]) if result[:output].includes?("No package found for")
      unless result[:rc] == 0
        raise YumVersionlockError.new("Error: #{result[:errout]}#{result[:output]}")
      end
    end

    # The real module's module-level C(match): a locklist entry matches a
    # requested spec when its parsed package name globs against the spec
    # (fnmatch, so wildcard specs like "httpd-*" work) OR the entry
    # stripped of its trailing ".*" wildcard equals the spec verbatim.
    # Entries that are not NEVRA-shaped never match - even verbatim ones.
    private def entry_matches(entry : String, spec : String) : Bool
      m = NEVRA_RE_YUM.match(entry) || NEVRA_RE_DNF.match(entry)
      return false unless m
      return true if File.match?(spec, m["name"])
      entry.rstrip(".*") == spec
    end

    private def run_yum(args : Array(String)) : {output: String, errout: String, rc: Int32}
      output = IO::Memory.new
      errout = IO::Memory.new
      rc = Process.run(YUM_BIN, args, output: output, error: errout).exit_code
      {output: output.to_s, errout: errout.to_s, rc: rc}
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
      # ansible-core (live-verified, see dnf_versionlock.cr's parse_names
      # / apt.cr's parse_package_names). A whole-value `{{ list_var }}`
      # container arg arrives as the double-quoted JSON the wire
      # serialized it to, which the JSON.parse above already handles.
      return [] of String if raw.empty?
      raw.includes?(",") ? raw.split(",").map(&.strip) : [raw]
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::YumVersionlockPlugin.new(config)
plugin.run
