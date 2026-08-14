#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/http_download"

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
  # Supported parameters (the shape both geerlingguy.docker and
  # geerlingguy.nodejs actually write - real Ansible's own module
  # supports many more DEB822 keys not implemented here: architectures,
  # trusted, enabled, allow_insecure, allow_downgrade_to_insecure,
  # allow_weak, pdiffs, by-hash, languages, targets, check_date,
  # check_valid_until, date_max_future - a documented scope cut, not an
  # oversight):
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
      check_mode = is_true?(@params["check_mode"]?)

      if state == "absent"
        return remove(target, check_mode)
      end

      uris = @params["uris"]?
      suites = @params["suites"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: uris") unless uris
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: suites") unless suites

      add(target, check_mode)
    end

    private def render_content(check_mode : Bool = false) : String
      n = @params["name"]?.not_nil!
      lines = [] of String
      lines << "Types: #{(@params["types"]? || "deb").gsub(',', ' ')}"
      lines << "URIs: #{@params["uris"]?.to_s.gsub(',', ' ')}"
      lines << "Suites: #{@params["suites"]?.to_s.gsub(',', ' ')}"
      if components = @params["components"]?
        lines << "Components: #{components.gsub(',', ' ')}"
      end
      if architectures = @params["architectures"]?
        lines << "Architectures: #{architectures.gsub(',', ' ')}"
      end
      lines << "X-Repolib-Name: #{n}"
      if (sb = resolve_signed_by(check_mode)) && !sb.empty?
        if sb.starts_with?('\n')
          lines << "Signed-By:#{sb}"
        else
          lines << "Signed-By: #{sb}"
        end
      end
      lines.join('\n') + '\n'
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
        name = @params["name"]?.not_nil!
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
      armored = File.open(tmp_path, "r") { |f| (f.gets(60) || "").starts_with?("-----BEGIN PGP") }

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
