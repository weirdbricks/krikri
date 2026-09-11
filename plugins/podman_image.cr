#!/usr/bin/env crystal
# containers.podman.podman_image - manages podman images (pull/remove).
# Ported subset of containers.podman's podman_image module (round 300134:
# ikke_t.podman_container_systemd pulls images through it; previously
# unavailable -> rc=4 "unavailable modules").
#
# Supported here: name (image reference with optional registry/tag),
# tag (appended when name carries none), state (present/absent), force
# (re-pull even when the image exists; changed when the image ID moved),
# username/password (passed as --creds to pull), executable (default
# podman), pull_extra_args. The module's push:/build-from-Containerfile
# paths are not ported.
#
# Idempotency: `podman image exists <ref>` decides presence; pull only
# runs when absent or force, and the before/after image ID comparison
# decides changed (a re-pull that lands on the same ID is not a change).
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/podman_image"

module Krikri
  class PodmanImagePlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return PluginResult.new(changed: false, failed: true,
        msg: "missing required argument: name") unless name

      tag = @params["tag"]?
      reference = PluginHelpers::PodmanImage.build_reference(name, tag)
      state = @params["state"]? || "present"
      unless state == "present" || state == "absent"
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: present, absent, got #{state}")
      end
      force = true?(@params["force"]?)
      executable = @params["executable"]?.presence || "podman"

      bin_ok = remote_exec("command -v #{executable}")
      return PluginResult.new(changed: false, failed: true,
        msg: "Failed to find required executable #{executable} in paths: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin") if bin_ok[:exit_code] != 0

      exists = remote_exec("#{executable} image exists #{reference}")
      image_exists = exists[:exit_code] == 0

      if state == "absent"
        return PluginResult.new(changed: false, failed: false,
          msg: "Image not found") unless image_exists
        rmi = remote_exec("#{executable} rmi -f #{reference}")
        return PluginResult.new(changed: false, failed: true,
          msg: "Failed to remove image #{reference}: #{rmi[:stderr]}") if rmi[:exit_code] != 0
        return PluginResult.new(changed: true, failed: false,
          msg: "Removed image #{reference}")
      end

      return PluginResult.new(changed: false, failed: false,
        msg: "Image already exists") if image_exists && !force

      image_id_before = image_id(executable, reference)
      creds = build_creds
      pull = remote_exec("#{executable} pull#{creds} #{reference}#{extra_args}")
      return PluginResult.new(changed: false, failed: true,
        msg: "Failed to pull image #{reference}: #{pull[:stderr].presence || pull[:stdout]}") if pull[:exit_code] != 0

      image_id_after = image_id(executable, reference)
      changed = !image_exists || image_id_before != image_id_after
      PluginResult.new(changed: changed, failed: false,
        msg: "Updated podman image: #{reference}", podman_image: image_id_after)
    end

    private def build_creds : String
      PluginHelpers::PodmanImage.creds_argument(@params["username"]?.presence, @params["password"]?.presence)
    end

    private def extra_args : String
      args = @params["pull_extra_args"]?.presence
      args ? " #{args}" : ""
    end

    private def image_id(executable : String, reference : String) : String?
      inspect = remote_exec("#{executable} image inspect --format '{{.Id}}' #{reference}")
      inspect[:exit_code] == 0 ? inspect[:stdout].strip.presence : nil
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PodmanImagePlugin.new(config)
plugin.run
