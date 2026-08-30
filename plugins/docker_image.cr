#!/usr/bin/env crystal

require "json"
require "docr"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/docker_ref"
require "../src/krikri/plugin_helpers/docker_client"

module Krikri
  # Docker image plugin - pulls or removes a local Docker image.
  # Compatible with Ansible's community.docker.docker_image module.
  #
  # Talks to the Docker Engine API directly - a local UNIX socket by
  # default, or a remote daemon over TCP(+TLS) via docker_host:/TLS
  # params below (see PluginHelpers::DockerClient) - the same thing real
  # Ansible's own community.docker collection does, via the Docker SDK
  # for Python, using the docr shard. See the weirdbricks/docr fork's
  # commit history for the reconnect/DOCKER_HOST/nullable-field/TCP+TLS
  # fixes this plugin depends on; upstream marghidanu/docr as of 0.1.4
  # has a "This HTTP::Client cannot be reconnected" bug that surfaces on
  # anything past a single call, and no way to reach a remote daemon at
  # all.
  #
  # Supported parameters:
  # - name: image reference, with or without a tag (required)
  # - tag: tag to use instead of a tag embedded in name: (default "latest"
  #   when name: has none)
  # - state: present (default) / absent (remove if present)
  # - source: required when state: present, same as real Ansible
  #   (required_if, verified - it has no default there either). Only
  #   "pull" is implemented - "build"/"load"/"local" (real Ansible's other
  #   source: values) are not
  # - check_mode
  #
  # - docker_host: / tls: / validate_certs: (alias tls_verify:) / cacert_path: /
  #   cert_path: / key_path: - connect to a remote Docker daemon over
  #   TCP(+TLS) instead of the local UNIX socket - see
  #   PluginHelpers::DockerClient's own doc comment for exact behavior
  #   (including tls_hostname:/DOCKER_TLS*/DOCKER_CERT_PATH support).
  #
  # - force_source: with state: present, re-pulls even when the image
  #   already exists locally - verified against real Ansible's own
  #   `present()` source (`if not image or self.force_source:`). A
  #   forced re-pull that resolves to the exact same image digest it
  #   already had reports `changed: false` (real Ansible's own source
  #   re-checks the image ID before/after and resets `changed` back to
  #   false on a match - NOT an unconditional `changed: true` the way a
  #   naive reading of the trigger condition alone would suggest) -
  #   caught live against a real Docker daemon: initially implemented as
  #   unconditional `changed: true`, then found to diverge from real
  #   ansible-playbook's own observed `changed: false` for this exact
  #   scenario before this was fixed.
  #
  # Not implemented: force_tag (only meaningful for real Ansible's own
  # `repo_tags:`-based re-tag-to-a-different-repository feature, which
  # isn't implemented here at all - a param modifying an unimplemented
  # feature, not a standalone gap), `api_version:` (see
  # PluginHelpers::DockerClient), build/archive/repository sources.
  class DockerImagePlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      state = @params["state"]? || "present"

      if state == "present"
        source = @params["source"]?
        unless source
          return PluginResult.new(changed: false, failed: true, msg: "state is present but all of the following are missing: source")
        end
        unless source == "pull"
          return PluginResult.new(changed: false, failed: true, msg: "docker_image: only source: pull is implemented, got '#{source}'")
        end
      end
      check_mode = true?(@params["check_mode"]?)

      ref_name, default_tag = PluginHelpers::DockerRef.split(name)
      ref_tag = @params["tag"]? || default_tag
      full_ref = PluginHelpers::DockerRef.join(ref_name, ref_tag)

      client, docker_host_description = PluginHelpers::DockerClient.build(@params)
      api = Docr::API.new(client)

      pre_pull_id = image_id(client, full_ref)
      exists = !pre_pull_id.nil?
      force_source = true?(@params["force_source"]?)

      case state
      when "present"
        present_result(client, api, ref_name, ref_tag, full_ref, pre_pull_id, exists, force_source, check_mode)
      when "absent"
        absent_result(api, full_ref, exists, check_mode)
      else
        PluginResult.new(changed: false, failed: true, msg: "state must be 'present' or 'absent', got '#{state}'")
      end
    rescue ex : Docr::Errors::DockerAPIError
      PluginResult.new(changed: false, failed: true, msg: "Docker API error: #{ex.message}")
    rescue ex : Socket::ConnectError
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the Docker daemon (#{docker_host_description}): #{ex.message}")
    end

    private def present_result(
      client : Docr::Client, api : Docr::API, ref_name : String, ref_tag : String,
      full_ref : String, pre_pull_id : String?, exists : Bool,
      force_source : Bool, check_mode : Bool,
    ) : PluginResult
      if exists && !force_source
        PluginResult.new(changed: false, failed: false, msg: "Image #{full_ref} already present")
      elsif check_mode
        PluginResult.new(changed: true, failed: false, msg: "Image #{full_ref} would be pulled")
      else
        api.images.create(ref_name, ref_tag)
        # force_source: re-pulling an image that resolves to the
        # exact same digest it already had is a real no-op - see
        # #image_id's own doc comment for why this matters and what
        # real Ansible's source does.
        unchanged = exists && image_id(client, full_ref) == pre_pull_id
        PluginResult.new(
          changed: !unchanged,
          failed: false,
          msg: pull_result_msg(full_ref, unchanged, exists)
        )
      end
    end

    private def pull_result_msg(full_ref : String, unchanged : Bool, exists : Bool) : String
      if unchanged
        "Image #{full_ref} already present (force_source, unchanged)"
      elsif exists
        "Re-pulled image #{full_ref} (force_source)"
      else
        "Pulled image #{full_ref}"
      end
    end

    private def absent_result(api : Docr::API, full_ref : String, exists : Bool, check_mode : Bool) : PluginResult
      if !exists
        PluginResult.new(changed: false, failed: false, msg: "Image #{full_ref} already absent")
      elsif check_mode
        PluginResult.new(changed: true, failed: false, msg: "Image #{full_ref} would be removed")
      else
        api.images.delete(full_ref, force: true)
        PluginResult.new(changed: true, failed: false, msg: "Removed image #{full_ref}")
      end
    end

    # Existence check via a raw GET rather than Images#inspect: we only
    # need a yes/no answer, so there's no reason to pull in (and trust)
    # docr's much larger, less-exercised Docr::Types::Image parse just to
    # throw the result away.
    private def image_exists?(client : Docr::Client, ref : String) : Bool
      !image_id(client, ref).nil?
    end

    # The image's own "Id" field (a "sha256:..." digest) via a raw GET -
    # same minimal-trust approach as the old image_exists? (no reason to
    # pull in docr's much larger Docr::Types::Image parse just for one
    # field). nil if the image doesn't exist.
    #
    # Used for force_source:'s own idempotency re-check - verified
    # against real Ansible's own `present()` source: after a forced
    # re-pull, if the image existed BEFORE and its ID is UNCHANGED
    # after, `changed` is reset back to false (`if image and image["Id"]
    # == self.results["image"]["Id"]: self.results["changed"] = False`)
    # - a force_source-triggered pull that resolves to the identical,
    # already-current image is a real no-op, not a "changed" pull.
    private def image_id(client : Docr::Client, ref : String) : String?
      id = nil
      client.call("GET", "/images/#{ref}/json") do |response|
        id = JSON.parse(response.body_io).dig?("Id").try(&.as_s?)
      end
      id
    rescue ex : Docr::Errors::DockerAPIError
      return nil if ex.status_code == 404
      raise ex
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::DockerImagePlugin.new(config)
plugin.run
