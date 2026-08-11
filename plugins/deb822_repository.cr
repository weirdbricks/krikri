#!/usr/bin/env crystal

require "json"
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
  # - signed_by: a path to an *already-local* keyring/armored-key file
  #   (real Ansible's own module also accepts a URL to fetch-and-dearmor,
  #   or inline ASCII-armored key text written directly into the
  #   Signed-By: field - neither implemented here; every real playbook
  #   seen so far downloads the key separately via get_url: first,
  #   exactly like geerlingguy.nodejs's own "Download NodeSource's
  #   signing key." task immediately before this one, then passes the
  #   local dest: path)
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
      if signed_by = @params["signed_by"]?
        lines << "Signed-By: #{signed_by}"
      end
      lines.join('\n') + '\n'
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
