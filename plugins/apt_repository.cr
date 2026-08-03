#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/apt_repository_line"

module CrystalPlay
  # Apt_repository plugin - adds/removes a Debian/Ubuntu APT source line.
  # Compatible with Ansible's ansible.builtin.apt_repository module.
  #
  # Supported parameters:
  # - repo: a plain "deb ..."/"deb-src ..." source line (required)
  # - state: present (default) | absent
  # - filename: base filename (without .list) to use under
  #   /etc/apt/sources.list.d/ - defaults to a name derived from the repo
  #   URL via PluginHelpers::AptRepositoryLine, replicating real
  #   Ansible's own `_suggest_filename` logic exactly (see that module
  #   for details, verified against real Ansible's actual source)
  # - update_cache: run `apt-get update` after a change (default true)
  # - mode: applied to the resulting file
  # - check_mode: report what would change without writing anything
  #
  # Idempotency: checks whether the normalized repo line already appears,
  # enabled, in /etc/apt/sources.list or any /etc/apt/sources.list.d/*.list
  # file - not just the target file - matching real Ansible's own
  # SourcesList, which reads all of them before deciding whether an
  # add/remove is a no-op.
  #
  # Not implemented: `ppa:` shorthand (resolves a PPA's GPG key and
  # codename via the Launchpad API - a real network dependency, out of
  # scope the same way other network-resolving plugins in this codebase
  # are), `codename`, `install_python_apt` (crystal-ansible never shells
  # out to python-apt in the first place), `validate_certs`,
  # `update_cache_retries`/`update_cache_retry_max_delay`.
  class AptRepositoryPlugin < BasePlugin
    SOURCES_LIST   = "/etc/apt/sources.list"
    SOURCES_LIST_D = "/etc/apt/sources.list.d"

    def execute : PluginResult
      repo = @params["repo"]?
      unless repo
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: repo")
      end

      normalized = PluginHelpers::AptRepositoryLine.normalize(repo)
      unless normalized
        return PluginResult.new(changed: false, failed: true, msg: "Invalid repo line: #{repo}")
      end

      state = @params["state"]? || "present"
      update_cache = is_true?(@params["update_cache"]?, default: true)
      check_mode = is_true?(@params["check_mode"]?)

      if state == "absent"
        remove(normalized, update_cache, check_mode)
      else
        add(normalized, update_cache, check_mode)
      end
    end

    private def all_source_files : Array(String)
      list_d = remote_exec("ls #{SOURCES_LIST_D}/*.list 2>/dev/null")[:stdout].split("\n").map(&.strip).reject(&.empty?)
      [SOURCES_LIST] + list_d
    end

    private def find_source(normalized : String) : String?
      all_source_files.find do |file|
        remote_exec("grep -qxF #{shell_quote(normalized)} #{file} 2>/dev/null")[:exit_code] == 0
      end
    end

    private def add(normalized : String, update_cache : Bool, check_mode : Bool) : PluginResult
      if find_source(normalized)
        return PluginResult.new(changed: false, failed: false, msg: "", repo: normalized, state: "present")
      end

      if check_mode
        return PluginResult.new(changed: true, failed: false, msg: "Would add repository (check mode)", repo: normalized, state: "present")
      end

      target = target_file(normalized)
      remote_exec("mkdir -p #{File.dirname(target)}")
      remote_exec("echo #{shell_quote(normalized)} >> #{target}")
      apply_mode(target)
      run_update_cache if update_cache

      PluginResult.new(changed: true, failed: false, msg: "", repo: normalized, state: "present")
    end

    private def remove(normalized : String, update_cache : Bool, check_mode : Bool) : PluginResult
      file = find_source(normalized)
      unless file
        return PluginResult.new(changed: false, failed: false, msg: "", repo: normalized, state: "absent")
      end

      if check_mode
        return PluginResult.new(changed: true, failed: false, msg: "Would remove repository (check mode)", repo: normalized, state: "absent")
      end

      # grep -v exits 1 (not just "no match found") whenever every line
      # gets filtered out - the common case for a single-line file - so
      # this can't be `grep ... && mv ...`: that silently skips the mv
      # and leaves the original file untouched. Caught by running a
      # remove twice in a row against real ansible-playbook and finding
      # crystal-ansible reported changed: true both times.
      remote_exec("grep -vxF #{shell_quote(normalized)} #{file} > #{file}.crystal-ansible-tmp; mv #{file}.crystal-ansible-tmp #{file}")
      remaining = remote_exec("grep -c . #{file} 2>/dev/null")[:stdout].strip
      remote_exec("rm -f #{file}") if remaining == "0" && file != SOURCES_LIST
      run_update_cache if update_cache

      PluginResult.new(changed: true, failed: false, msg: "", repo: normalized, state: "absent")
    end

    private def target_file(normalized : String) : String
      if filename = @params["filename"]?
        return File.join(SOURCES_LIST_D, "#{filename}.list")
      end

      File.join(SOURCES_LIST_D, "#{PluginHelpers::AptRepositoryLine.suggested_filename(normalized)}.list")
    end

    private def run_update_cache
      remote_exec("apt-get update")
    end

    private def apply_mode(path : String)
      if mode = @params["mode"]?
        remote_exec("chmod #{mode} #{path}")
      end
    end

    private def shell_quote(value : String) : String
      "\"#{value.gsub("\"", "\\\"")}\""
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::AptRepositoryPlugin.new(config)
plugin.run
