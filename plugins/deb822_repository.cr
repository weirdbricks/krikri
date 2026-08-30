#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/http_download"
require "../src/crystal_play/plugin_helpers/deb822_repository_content"

module CrystalPlay
  # Deb822_repository plugin - adds/removes a DEB822-format (`.sources`)
  # APT repository file. Compatible with (a subset of) Ansible's
  # ansible.builtin.deb822_repository module (ansible-core 2.15+, the
  # modern replacement for a plain apt_repository: source line, now what
  # current NodeSource/Docker-style install docs tell users to write).
  #
  # Real gap found benchmarking geerlingguy.nodejs's own "Add NodeSource
  # repositories for Node.js." task, which uses exactly this module -
  # previously entirely unimplemented (already flagged in
  # KNOWN_MISSING.md from geerlingguy.docker hitting the same gap: its
  # own "Add or remove Docker repository." task skipped identically).
  # With the repo never actually added, apt-get never sees the
  # NodeSource suite at all, so "Ensure Node.js and npm are installed."
  # fails outright (`nodejs=20.x*` isn't available from any configured
  # source) - not a silent divergence, a hard failure with no
  # obvious tie back to the skipped task.
  #
  # Supported parameters (the core shape both geerlingguy.docker and
  # geerlingguy.nodejs actually write, plus every other real DEB822 key
  # real Ansible's own module supports: architectures, trusted, enabled,
  # allow_insecure, allow_downgrade_to_insecure, allow_weak, pdiffs,
  # by_hash, languages, targets, check_date, check_valid_until,
  # date_max_future - closed in a later proactive scope-cut audit pass,
  # verified against the real module's own source for exact field-name/
  # value-format conversion; only `inrelease_path` remains genuinely
  # unimplemented, a rare param for pinning a specific InRelease file
  # path):
  # - name (required): base filename under /etc/apt/sources.list.d/,
  #   written as <name>.sources
  # - types: deb (default) | deb-src | "deb deb-src"
  # - uris (required): the repo URL(s), space-separated if more than one
  # - suites (required): distro suite/codename(s)
  # - components: repo component(s), e.g. "main"
  # - signed_by: a path to an *already-local* keyring/armored-key file,
  #   OR a URL - fetched (binary-safe, redirect-aware, matching
  #   get_url.cr's own response.body_io streaming rather than a UTF-8-
  #   decoding String read), stored as `.asc` (ASCII-armored) or `.gpg`
  #   (binary) under `/etc/apt/keyrings/<name>{.asc,.gpg}` (real Ansible's
  #   own naming convention - no `gpg --dearmor` involved, the fork stores
  #   armored keys verbatim) - the *local* path is what actually lands in
  #   the rendered Signed-By: field after the key has been fetched and
  #   stored. OR inline ASCII-armored GPG key text, detected by its
  #   "-----BEGIN PGP" leading bytes and rendered as a Deb822 folded
  #   multi-line value (indented continuation lines, matching real
  #   Ansible's own format_multiline). OR a key fingerprint (40 hex chars),
  #   space-normalized and emitted literally on one line.
  # - state: present (default) | absent
  # - mode: applied to the resulting file (default "0644", matching
  #   real Ansible's own module default)
  #
  # Idempotency: compares the fully-rendered file content against
  # whatever's already on disk at the target path - matching real
  # Ansible's own module, which rewrites (not merges) the whole file
  # and reports changed based on a content diff.
  class Deb822RepositoryPlugin < BasePlugin
    SOURCES_LIST_D = "/etc/apt/sources.list.d"

    def execute : PluginResult
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name") unless name

      state = @params["state"]? || "present"
      target = File.join(SOURCES_LIST_D, "#{name}.sources")
      check_mode = true?(@params["check_mode"]?)

      if state == "absent"
        return remove(target, check_mode)
      end

      uris = @params["uris"]?
      suites = @params["suites"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: uris") unless uris
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: suites") unless suites

      add(target, check_mode)
    end

    BOOL_FIELDS = {
      "trusted" => "Trusted", "enabled" => "Enabled", "allow_insecure" => "Allow-Insecure",
      "allow_downgrade_to_insecure" => "Allow-Downgrade-To-Insecure", "allow_weak" => "Allow-Weak",
      "pdiffs" => "Pdiffs", "by_hash" => "By-Hash", "check_date" => "Check-Date",
      "check_valid_until" => "Check-Valid-Until",
    }
    LIST_FIELDS = {
      "types" => "Types", "uris" => "URIs", "suites" => "Suites", "components" => "Components",
      "architectures" => "Architectures", "languages" => "Languages", "targets" => "Targets",
    }

    # Real ansible.builtin.deb822_repository writes fields in ALPHABETICAL
    # ORDER BY THE UNDERLYING PARAM NAME, not by field name and not in
    # any fixed/declared order (`for key, value in sorted(params.items())`)
    # - verified directly against a real ansible-playbook -vvv run's own
    # `repo:` return value, not assumed from source alone. This matters
    # for idempotency: a file real Ansible itself wrote and a file this
    # plugin writes must line up byte-for-byte, or a warm rerun against
    # an already-real-Ansible-managed file would spuriously report
    # changed every time on line-order alone even though nothing
    # meaningful differs. Bool fields (all `type: bool` in the real
    # module's own argument_spec) are written as literal "yes"/"no" -
    # real APT's own deb822 sources parser (and this codebase's own
    # `true?`) both already understand "yes"/"no"/"true"/"false"
    # interchangeably, so round-tripping an already-boolean-ish param
    # value through `true?` first (rather than assuming it always
    # arrives as literal "true"/"false") stays correct either way.
    private def render_content(check_mode : Bool = false) : String
      n = @params["name"]? || raise "deb822_repository: name is required"
      fields = {} of String => String

      add_bool_fields(fields)
      add_list_fields(fields)
      add_scalar_fields(fields, n, check_mode)

      PluginHelpers::Deb822RepositoryContent.render(fields)
    end

    # Bool fields (all `type: bool` in the real module's own
    # argument_spec) are written as literal "yes"/"no" - real APT's own
    # deb822 sources parser (and this codebase's own `true?`) both
    # already understand "yes"/"no"/"true"/"false" interchangeably, so
    # round-tripping an already-boolean-ish param value through `true?`
    # first (rather than assuming it always arrives as literal
    # "true"/"false") stays correct either way.
    private def add_bool_fields(fields : Hash(String, String)) : Nil
      BOOL_FIELDS.each do |param, field|
        fields[param] = "#{field}: #{true?(@params[param]?) ? "yes" : "no"}" if @params[param]?
      end
    end

    private def add_list_fields(fields : Hash(String, String)) : Nil
      LIST_FIELDS.each do |param, field|
        default = param == "types" ? "deb" : nil
        value = @params[param]? || default
        fields[param] = "#{field}: #{value.gsub(',', ' ')}" if value
      end
    end

    # The remaining single-value fields: date_max_future, the X-Repolib-
    # Name header and the resolved Signed-By value
    private def add_scalar_fields(fields : Hash(String, String), n : String, check_mode : Bool) : Nil
      if date_max_future = @params["date_max_future"]?
        fields["date_max_future"] = "Date-Max-Future: #{date_max_future}"
      end
      fields["name"] = "X-Repolib-Name: #{n}"
      if (sb = resolve_signed_by(check_mode)) && !sb.empty?
        fields["signed_by"] = sb.starts_with?('\n') ? "Signed-By:#{sb}" : "Signed-By: #{sb}"
      end
    end

    private def resolve_signed_by(check_mode : Bool = false) : String?
      raw = @params["signed_by"]?
      return nil unless raw

      # 1. Local path — return unchanged (matches real Ansible's own
      #    os.path.isfile(v) branch).
      return raw if File.exists?(raw)

      # 2. URL — fetch (redirect-aware), store as .asc (armored) or .gpg
      #    (binary) under /etc/apt/keyrings/<name>{.asc,.gpg}, return the
      #    local path for Signed-By:
      if (scheme = URI.parse(raw).scheme) && %w[http https].includes?(scheme.downcase)
        name = @params["name"]? || raise "deb822_repository: name is required"
        return resolve_url_signed_by(name, raw, check_mode)
      end

      # 3. Inline ASCII-armored GPG key text — render as Deb822 folded
      #    multi-line value (indented with 4 spaces on each continuation
      #    line, matching real Ansible's own format_multiline output).
      if raw.lstrip.starts_with?("-----BEGIN PGP")
        return format_inline_key(raw)
      end

      # 4. Key fingerprint(s) — space-normalize (commas → spaces, collapse
      #    whitespace runs) and emit on one line.
      raw.gsub(',', ' ').split.join(' ')
    end

    private def resolve_url_signed_by(name : String, url : String, check_mode : Bool) : String
      keyring_dir = "/etc/apt/keyrings"
      keyring_path_asc = File.join(keyring_dir, "#{name}.asc")
      keyring_path_gpg = File.join(keyring_dir, "#{name}.gpg")

      # In check mode, skip the network download entirely — just return
      # the expected keyring path based on any existing file (default to
      # .asc since we can't know whether the remote key is armored without
      # fetching it). The content diff against a non-existent keyring will
      # correctly show "changed=true".
      if check_mode
        return keyring_path_asc unless File.exists?(keyring_path_gpg)
        return keyring_path_gpg
      end

      Dir.mkdir_p(keyring_dir)
      File.chmod(keyring_dir, 0o755) if File.exists?(keyring_dir)

      # Download to a temp file to detect armored vs binary content
      tmp_path = "#{keyring_dir}/.#{name}.#{Process.pid}.tmp"
      download_binary(url, tmp_path)

      # Detect ASCII-armored content by checking the first bytes
      armored = File.open(tmp_path, "r") { |fval| (fval.gets(60) || "").starts_with?("-----BEGIN PGP") }

      ext = armored ? ".asc" : ".gpg"
      keyring_path = File.join(keyring_dir, "#{name}#{ext}")

      # Check if the keyring content actually changed (idempotency) —
      # avoids rewriting the keyring on every run when the key hasn't
      # changed upstream.
      changed = !File.exists?(keyring_path) || File.read(keyring_path) != File.read(tmp_path)
      if changed
        File.rename(tmp_path, keyring_path)
        File.chmod(keyring_path, 0o644)
      else
        File.delete(tmp_path) if File.exists?(tmp_path)
      end

      keyring_path
    end

    private def format_inline_key(raw : String) : String
      # Real Ansible's own format_multiline: strips whitespace, replaces
      # empty lines with '.', indents each line with 4 spaces, then
      # prepends a leading newline so the whole block becomes a Deb822
      # folded continuation value after "Signed-By:".
      folded = raw.strip.lines.map do |line|
        stripped = line.strip
        "    #{(stripped.empty? ? "." : stripped)}"
      end
      "\n" + folded.join("\n")
    end

    # Binary-safe download with redirect following — response.body_io
    # streamed straight to disk. Delegates to the shared HTTPDownload
    # helper (also used by get_url.cr) so the two plugins share one
    # redirect-tracking implementation and can't drift apart. Many real
    # key URLs (keys.openpgp.org, packages.*) redirect at least once, and
    # without redirect following every such key download silently fails.
    private def download_binary(url : String, dest : String) : Nil
      PluginHelpers::HTTPDownload.download(url, dest)
    end

    private def add(target : String, check_mode : Bool) : PluginResult
      new_content = render_content(check_mode)
      existing = File.exists?(target) ? File.read(target) : nil
      changed = existing != new_content

      if check_mode
        return PluginResult.new(changed: changed, failed: false, msg: changed ? "Would write #{target} (check mode)" : "Already up to date")
      end

      unless changed
        return PluginResult.new(changed: false, failed: false, msg: "Already up to date")
      end

      Dir.mkdir_p(SOURCES_LIST_D)
      File.write(target, new_content)
      apply_owner_group_mode(target, nil, nil, @params["mode"]? || "0644")

      PluginResult.new(changed: true, failed: false, msg: "Repository added", path: target)
    end

    private def remove(target : String, check_mode : Bool) : PluginResult
      unless File.exists?(target)
        return PluginResult.new(changed: false, failed: false, msg: "Repository already absent")
      end

      if check_mode
        return PluginResult.new(changed: true, failed: false, msg: "Would remove #{target} (check mode)")
      end

      File.delete(target)
      PluginResult.new(changed: true, failed: false, msg: "Repository removed", path: target)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::Deb822RepositoryPlugin.new(config)
plugin.run
