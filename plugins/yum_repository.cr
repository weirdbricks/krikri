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
  #   state=present (matches real Ansible's own validation). `baseurl`/
  #   `gpgkey` are comma-separated lists (real Ansible's own `type: list`) -
  #   real Ansible joins them with `\n` before handing the value to
  #   Python's `configparser`, which itself then renders a multi-line
  #   value as a tab-indented continuation line
  #   (`baseurl = http://a\n\thttp://b\n`, verified directly against real
  #   `configparser` output, not assumed), not a bare embedded newline -
  #   `exclude`/`includepkgs` below stay space-joined on one line instead,
  #   a real, different treatment verified against real Ansible's own
  #   source (`'\n'.join(v)` vs `' '.join(v)`); a real,
  #   previously-mis-categorized bug in this codebase fixed alongside the
  #   knobs below (`baseurl` used to be treated as a single plain string,
  #   silently wrong for the multi-URL case real Ansible's own `list` type
  #   supports).
  # - gpgcheck / enabled / countme / enablegroups / keepalive /
  #   module_hotfixes / protect / repo_gpgcheck / s3_enabled /
  #   skip_if_unavailable / ssl_check_cert_permissions / sslverify:
  #   booleans, rendered as 1/0
  # - gpgkey (see baseurl above) / exclude / includepkgs: lists,
  #   `exclude`/`includepkgs` space-joined on one line
  # - priority, bandwidth, cost, deltarpm_metadata_percentage,
  #   deltarpm_percentage, failovermethod, gpgcakey, http_caching,
  #   include, ip_resolve, keepcache, metadata_expire,
  #   metadata_expire_filter, mirrorlist_expire, password, proxy,
  #   proxy_password, proxy_username, retries, sslcacert, sslclientcert,
  #   sslclientkey, throttle, timeout, ui_repoid_vars, username: plain
  #   string/int values written as-is - real Ansible validates a handful
  #   of these against a fixed choice list (`failovermethod`,
  #   `http_caching`, `ip_resolve`, `keepcache`), which this plugin
  #   doesn't replicate (a real, minor scope cut - an invalid value is
  #   passed straight through and surfaces as whatever error `dnf`/`yum`
  #   itself gives, the same "no client-side choice validation" pattern
  #   several other plugins in this codebase already have). Several of
  #   these (`deltarpm_metadata_percentage`, `gpgcakey`, `http_caching`,
  #   `keepalive`, `metadata_expire_filter`, `mirrorlist_expire`,
  #   `protect`, `ssl_check_cert_permissions`, `ui_repoid_vars`) are
  #   themselves deprecated in real Ansible as of 2.20-2.22 ("has no
  #   effect with dnf as an underlying package manager") - real Ansible
  #   still *writes* them to the file (only emits a deprecation warning),
  #   so this plugin does too, matching actual file output rather than
  #   the deprecation status.
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
  # Not implemented: `async` (a legacy, Python-reserved-word-workaround
  # param, essentially unused in real playbooks), `exclude:`'s
  # `excludepkgs` alias, `no_log` redaction of `password:`/
  # `proxy_password:` from output (not implemented by any plugin in this
  # codebase), SELinux options, `attributes`, `unsafe_writes`.
  #
  # Like `apt_repository.cr`, this plugin is entirely file editing - no
  # actual `dnf`/`yum` call anywhere in it - so it's fully native
  # (`File.read`/`File.write`/`File.delete?`/`Dir.mkdir_p` replacing
  # `cat`/`rm -f`/`mkdir -p`, plus `BasePlugin#apply_owner_group_mode`
  # for `chown`/`chgrp`/`chmod`).
  class YumRepositoryPlugin < BasePlugin
    BOOL_KEYS = %w[
      enabled gpgcheck countme enablegroups keepalive module_hotfixes protect
      repo_gpgcheck s3_enabled skip_if_unavailable ssl_check_cert_permissions sslverify
    ]
    # Space-joined on one line (exclude/includepkgs); baseurl/gpgkey are
    # newline-joined instead, see NEWLINE_LIST_KEYS below - real Ansible's
    # own `' '.join(v)` vs `'\n'.join(v)`, not the same treatment.
    LIST_KEYS         = %w[exclude includepkgs]
    NEWLINE_LIST_KEYS = %w[baseurl gpgkey]
    STR_KEYS          = %w[
      mirrorlist metalink priority bandwidth cost deltarpm_metadata_percentage
      deltarpm_percentage failovermethod gpgcakey http_caching include ip_resolve
      keepcache metadata_expire metadata_expire_filter mirrorlist_expire password
      proxy proxy_password proxy_username retries sslcacert sslclientcert
      sslclientkey throttle timeout ui_repoid_vars username
    ]

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

    private def read_current(path : String) : String
      File.exists?(path) ? File.read(path) : ""
    end

    private def remove_repo(name : String, path : String) : PluginResult
      current = read_current(path)
      unless current.includes?("[#{name}]")
        return PluginResult.new(changed: false, failed: false, msg: "", repo: name, state: "absent")
      end

      diff = generate_unified_diff(current, "", path, path) if @diff_mode
      File.delete?(path)
      PluginResult.new(changed: true, failed: false, msg: "", diff: diff, repo: name, state: "absent")
    end

    private def write_repo(name : String, description : String, path : String) : PluginResult
      desired = render_section(name, description)
      current = read_current(path)
      changed = current != desired

      if changed
        diff = generate_unified_diff(current, desired, path, path) if @diff_mode
        Dir.mkdir_p(File.dirname(path))
        write_file(path, desired)
        apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
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

      NEWLINE_LIST_KEYS.each do |key|
        if value = @params[key]?
          # Python's configparser (what real Ansible's own module uses to
          # write the file) renders a multi-line value as a tab-indented
          # continuation line, not a bare embedded newline - verified
          # directly against real configparser output, not assumed:
          # "baseurl = http://a\n\thttp://b\n", not "...a\nhttp://b\n".
          lines[key] = value.split(",").map(&.strip).reject(&.empty?).join("\n\t")
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
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::YumRepositoryPlugin.new(config)
plugin.run
