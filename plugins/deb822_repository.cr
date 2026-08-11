#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "../src/crystal_play/base_plugin"

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
  #   OR a URL - fetched (binary-safe, matching get_url.cr's own
  #   response.body_io streaming rather than a UTF-8-decoding String
  #   read), dearmored via `gpg --dearmor` if it's ASCII-armored text
  #   (detected by its own "-----BEGIN PGP" leading bytes) or stored
  #   as-is if already binary, into `/etc/apt/keyrings/<name>-archive-
  #   keyring.gpg` (real Ansible's own exact naming convention) - the
  #   *local* path is what actually lands in the rendered Signed-By:
  #   field either way. Real gap found benchmarking geerlingguy.
  #   rabbitmq's own "Add RabbitMQ repository" task, which gives a bare
  #   `https://keys.openpgp.org/...` URL directly (unlike geerlingguy.
  #   docker/nodejs, which both download the key separately via
  #   get_url: first and pass a local path) - previously written
  #   completely literally into Signed-By:, which apt rejects outright
  #   ("not a fingerprint"). Inline ASCII-armored key text given
  #   directly as signed_by: (not a URL, not an existing local path)
  #   remains unimplemented - no real playbook seen yet writes it that
  #   way.
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

    private def render_content : String
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
      if signed_by = resolve_signed_by
        lines << "Signed-By: #{signed_by}"
      end
      lines.join('\n') + '\n'
    end

    private def resolve_signed_by : String?
      raw = @params["signed_by"]?
      return nil unless raw
      return raw unless raw.starts_with?("http://") || raw.starts_with?("https://")

      name = @params["name"]?.not_nil!
      keyring_dir = "/etc/apt/keyrings"
      keyring_path = File.join(keyring_dir, "#{name}-archive-keyring.gpg")
      Dir.mkdir_p(keyring_dir)

      tmp_path = "#{keyring_path}.#{Process.pid}.tmp"
      download_binary(raw, tmp_path)

      armored = File.open(tmp_path, "r") { |f| (f.gets(30) || "").starts_with?("-----BEGIN PGP") }
      if armored
        remote_exec("gpg --batch --yes --dearmor -o #{keyring_path} #{tmp_path}")
        File.delete(tmp_path) if File.exists?(tmp_path)
      else
        File.rename(tmp_path, keyring_path)
      end

      keyring_path
    end

    # Binary-safe download - response.body_io streamed straight to disk,
    # matching get_url.cr's own #download (a plain HTTP::Client#get with
    # a String-returning body would UTF-8-decode and corrupt arbitrary
    # binary GPG key bytes).
    private def download_binary(url : String, dest : String)
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 10.seconds
      client.read_timeout = 10.seconds

      client.get(uri.request_target) do |response|
        raise "server returned #{response.status_code}" unless response.status.success?
        File.open(dest, "w") { |file| IO.copy(response.body_io, file) }
      end
    ensure
      client.try(&.close)
    end

    private def add(target : String, check_mode : Bool) : PluginResult
      new_content = render_content
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
