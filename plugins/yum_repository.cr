#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
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
  # - argument_spec aliases (excludepkgs -> exclude, ca_cert -> sslcacert,
  #   client_cert -> sslclientcert, client_key -> sslclientkey,
  #   validate_certs -> sslverify): normalized to the canonical key before
  #   rendering, so an alias spelling never lands in the file as its own
  #   `excludepkgs = ...`-style key (real Ansible resolves aliases through
  #   _handle_aliases and then pops them from the params dict before the
  #   write loop). A present alias beats the canonical name when both are
  #   given - real Ansible's own _handle_aliases overwrite order, verified
  #   in stat.cr against real ansible-core.
  #
  # Each run regenerates the section from scratch using only the
  # parameters given THAT run - it does not merge with whatever's already
  # in the file. Verified against real ansible-playbook: rerunning with a
  # different set of parameters drops keys that were present before but
  # aren't passed this time. Not a bug to "fix" - matching this exactly is
  # the point.
  #
  # Within its own [name] section that regeneration is the whole story,
  # but the FILE is merged, not overwritten: real Ansible's own module
  # feeds the entire existing .repo file through Python's configparser
  # and writes back every section it didn't touch untouched, so two
  # yum_repository tasks sharing one `file:` (the normal main + source
  # repo pattern - round900982 jaredledvina.sensu_go_ansible writes
  # [sensu_go] and [sensu_go-source] into the same sensu_go.repo)
  # coexist instead of whichever task runs last silently clobbering the
  # other's section and both re-reporting changed: true on every rerun
  # forever.
  #
  # Not implemented: `async` (a legacy, Python-reserved-word-workaround
  # param, essentially unused in real playbooks - and removed from real
  # Ansible's own argument_spec entirely on devel), SELinux options,
  # `attributes`, `unsafe_writes`.
  # `no_log` redaction of `password:`/`proxy_password:` was investigated
  # (0.9.376) and found to be a non-issue as things stand: no plugin or
  # verbose mode anywhere in this codebase ever echoes raw task params to
  # output/logs at all (confirmed by searching for any params/invocation
  # dump - none exists), so there's currently no actual leak surface for
  # a redaction to close. Real Ansible's `no_log` is also a real task-level
  # keyword (`no_log: true`) entirely separate from this per-field
  # concern, and is unimplemented as a keyword too - a genuine future gap
  # if/when this codebase ever adds a verbose arg-echo mode, but not one
  # yet.
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
    # Real argument_spec aliases. Resolution happens in initialize: a
    # present alias OVERWRITES the canonical name (real ansible-core's
    # _handle_aliases order, same convention stat.cr verified), and the
    # alias key itself is removed so it can never render as its own
    # key in the .repo file - real Ansible pops aliases from the params
    # dict before its write loop for exactly that reason.
    PARAM_ALIASES = {
      "excludepkgs"    => "exclude",
      "ca_cert"        => "sslcacert",
      "client_cert"    => "sslclientcert",
      "client_key"     => "sslclientkey",
      "validate_certs" => "sslverify",
    }

    def initialize(config : JSON::Any)
      super(config)
      PARAM_ALIASES.each do |alias_name, canonical|
        if value = @params[alias_name]?
          @params[canonical] = value
          @params.delete(alias_name)
        end
      end
    end

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
        # Real Ansible's reposdir check fires for state=absent too, not
        # just the write path - a `state: absent` on a host with no
        # /etc/yum.repos.d fails with the same "Repo directory ... does
        # not exist." message (podman-diff yum_repository_edge_cases
        # D6-D8: real fails all three, this engine happily returned
        # changed=false for the absent branch).
        unless Dir.exists?(reposdir)
          return PluginResult.new(changed: false, failed: true, msg: "Repo directory '#{reposdir}' does not exist.")
        end
        return remove_repo(name, path)
      end

      description = @params["description"]?
      unless description
        return PluginResult.new(changed: false, failed: true, msg: "state is present but all of the following are missing: description")
      end

      unless @params["baseurl"]? || @params["mirrorlist"]? || @params["metalink"]?
        return PluginResult.new(changed: false, failed: true, msg: "state is present but any of the following are missing: baseurl, mirrorlist, metalink")
      end

      # Real Ansible's own yum_repository refuses to create *reposdir*
      # itself (`Repo directory '/etc/yum.repos.d' does not exist.`) -
      # confirmed live against a non-RPM (Ubuntu) target, where that
      # directory genuinely doesn't exist. Previously this plugin's own
      # write_repo silently `Dir.mkdir_p`'d it into existence instead,
      # which papers over the same "this host has no yum/dnf at all"
      # signal real Ansible's own check deliberately surfaces as a
      # module failure rather than a surprising directory creation.
      unless Dir.exists?(reposdir)
        return PluginResult.new(changed: false, failed: true, msg: "Repo directory '#{reposdir}' does not exist.")
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
      merged = merge_section(current, name, desired)
      # Compare whole file to whole file, not whole file to this task's
      # own section alone - with multiple sections in one file the old
      # whole-file-vs-single-section comparison could never converge.
      changed = merged != current

      if changed
        diff = generate_unified_diff(current, merged, path, path) if @diff_mode
        Dir.mkdir_p(File.dirname(path))
        write_file(path, merged)
        apply_owner_group_mode(path, @params["owner"]?, @params["group"]?, @params["mode"]?)
      end

      PluginResult.new(changed: changed, failed: false, msg: "", diff: diff, repo: name, state: "present")
    end

    # Real Ansible's own yum_repository runs Python's configparser over
    # the whole existing .repo file and rewrites just the one [name]
    # section the task is about, so every other section in the file
    # survives untouched (round900982 jaredledvina.sensu_go_ansible: two
    # tasks sharing one `file:` made the old write-the-whole-file path
    # drop the first task's section on every run). Sections other than
    # the task's own are preserved byte-for-byte; the rendered section
    # replaces its exact [name] block or is appended at the end with
    # configparser's own blank-line separation (real output verified
    # live: each section followed by exactly one blank line, the file
    # ending with one too).
    private def merge_section(current : String, name : String, desired : String) : String
      return desired if current.empty?

      lines = current.split("\n")
      header = "[#{name}]"
      starts = (0...lines.size).select { |idx| section_header?(lines[idx]) }
      target = starts.index { |idx| lines[idx].rstrip == header }

      if target
        block_start = starts[target]
        # A section block runs to the next [header] (or EOF); a
        # non-final block's trailing blank line is the separator
        # configparser puts between sections, so the replacement keeps
        # exactly one instead of accumulating an extra on every rewrite.
        block_end = target + 1 == starts.size ? lines.size - 1 : starts[target + 1] - 1
        replacement = block_end == lines.size - 1 ? desired.split("\n") : desired.split("\n")[0..-2]
        (lines[0...block_start] + replacement + lines[(block_end + 1)..]).join("\n")
      else
        stripped = current.rstrip("\n")
        stripped.empty? ? desired : stripped + "\n\n" + desired
      end
    end

    private def section_header?(line : String) : Bool
      line.starts_with?("[") && line.rstrip.ends_with?("]")
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
          lines[key] = true?(value) ? "1" : "0"
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

    private def write_file(path : String, content : String) : Nil
      if local_connection?
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

plugin = Krikri::YumRepositoryPlugin.new(config)
plugin.run
