#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Yum_repository plugin - manages .repo files under /etc/yum.repos.d/.
  # Compatible with Ansible's ansible.builtin.yum_repository module.
  #
  # Supported parameters:
  # - name: repository id / INI section name (required)
  # - description: human-readable text - written as the `name =` key
  #   INSIDE the file (a real, confirmed quirk: the module's own `name`
  #   param is the id/section, `description` is what ends up as the
  #   `name=` field in yum.conf terms - verified against real
  #   ansible-playbook's actual file output, not assumed)
  # - baseurl / mirrorlist / metalink: at least one required when
  #   state=present (matches real Ansible's own validation)
  # - gpgcheck / enabled: booleans, rendered as 1/0
  # - gpgkey / exclude / includepkgs: lists, space-joined on one line
  # - priority
  # - state: present (default) | absent
  # - file: filename without the `.repo` extension (default: `name`)
  # - reposdir: directory to write into (default: /etc/yum.repos.d)
  # - mode / owner / group: applied to the resulting .repo file
  #
  # Each run regenerates the section from scratch using only the
  # parameters given THAT run - it does not merge with whatever's already
  # in the file. Verified against real ansible-playbook: rerunning with a
  # different set of parameters drops keys that were present before but
  # aren't passed this time. Not a bug to "fix" - matching this exactly is
  # the point.
  #
  # Not implemented: the many lower-value/rarer yum.conf tuning knobs
  # (async, bandwidth, cost, deltarpm_*, http_caching, ip_resolve,
  # keepalive, keepcache, metadata_expire*, module_hotfixes, protect,
  # repo_gpgcheck, retries, s3_enabled, skip_if_unavailable, ssl*,
  # throttle, timeout, ui_repoid_vars, username/password/proxy_*,
  # unsafe_writes, countme, enablegroups, failovermethod, include),
  # SELinux options, `attributes`.
  class YumRepositoryPlugin < BasePlugin
    BOOL_KEYS = %w[enabled gpgcheck]
    LIST_KEYS = %w[gpgkey exclude includepkgs]
    STR_KEYS  = %w[baseurl mirrorlist metalink priority]

    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      state = @params["state"]? || "present"
      reposdir = @params["reposdir"]? || "/etc/yum.repos.d"
      file = @params["file"]? || name
      path = File.join(reposdir, "#{file}.repo")

      if state == "absent"
        return remove_repo(name, path)
      end

      description = @params["description"]?
      unless description
        return PluginResult.new(changed: false, failed: true, msg: "state is present but all of the following are missing: description")
      end

      unless @params["baseurl"]? || @params["mirrorlist"]? || @params["metalink"]?
        return PluginResult.new(changed: false, failed: true, msg: "state is present but any of the following are missing: baseurl, mirrorlist, metalink")
      end

      write_repo(name, description, path)
    end

    private def remove_repo(name : String, path : String) : PluginResult
      current = remote_exec("cat #{path} 2>/dev/null")[:stdout]
      unless current.includes?("[#{name}]")
        return PluginResult.new(changed: false, failed: false, msg: "", repo: name, state: "absent")
      end

      diff = generate_unified_diff(current, "", path, path) if @diff_mode
      remote_exec("rm -f #{path}")
      PluginResult.new(changed: true, failed: false, msg: "", diff: diff, repo: name, state: "absent")
    end

    private def write_repo(name : String, description : String, path : String) : PluginResult
      desired = render_section(name, description)
      current = remote_exec("cat #{path} 2>/dev/null")[:stdout]
      changed = current != desired

      if changed
        diff = generate_unified_diff(current, desired, path, path) if @diff_mode
        remote_exec("mkdir -p #{File.dirname(path)}")
        write_file(path, desired)
        apply_attributes(path)
      end

      PluginResult.new(changed: changed, failed: false, msg: "", diff: diff, repo: name, state: "present")
    end

    private def render_section(name : String, description : String) : String
      lines = {"name" => description} of String => String

      STR_KEYS.each do |key|
        if value = @params[key]?
          lines[key] = value
        end
      end

      BOOL_KEYS.each do |key|
        if value = @params[key]?
          lines[key] = is_true?(value) ? "1" : "0"
        end
      end

      LIST_KEYS.each do |key|
        if value = @params[key]?
          lines[key] = value.split(",").map(&.strip).reject(&.empty?).join(" ")
        end
      end

      String.build do |str|
        str << "[#{name}]\n"
        lines.keys.to_a.sort!.each { |key| str << "#{key} = #{lines[key]}\n" }
        str << "\n"
      end
    end

    private def write_file(path : String, content : String)
      if is_local_connection?
        File.write(path, content)
      else
        tmp = File.tempname
        File.write(tmp, content)
        remote_upload(tmp, path)
        File.delete(tmp)
      end
    end

    private def apply_attributes(path : String)
      if owner = @params["owner"]?
        remote_exec("chown #{owner} #{path}")
      end
      if group = @params["group"]?
        remote_exec("chgrp #{group} #{path}")
      end
      if mode = @params["mode"]?
        remote_exec("chmod #{mode} #{path}")
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::YumRepositoryPlugin.new(config)
plugin.run
