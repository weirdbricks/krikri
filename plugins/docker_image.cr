#!/usr/bin/env crystal

require "json"
require "docr"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/docker_ref"

module CrystalPlay
  # Docker image plugin - pulls or removes a local Docker image.
  # Compatible with Ansible's community.docker.docker_image module.
  #
  # Talks to the Docker Engine API directly over its UNIX socket (real
  # Ansible's own community.docker collection does the same, via the
  # Docker SDK for Python) using the docr shard - see the weirdbricks/docr
  # fork's commit history for the reconnect/DOCKER_HOST/nullable-field
  # fixes this plugin depends on; upstream marghidanu/docr as of 0.1.4 has
  # a "This HTTP::Client cannot be reconnected" bug that surfaces on
  # anything past a single call.
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
  # Not implemented: force_tag, force_source, docker_host/tls connection
  # options (this plugin always talks to the local daemon - DOCKER_HOST
  # env var or /var/run/docker.sock, same as every other plugin in this
  # codebase being local-first), build/archive/repository sources.
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
      check_mode = is_true?(@params["check_mode"]?)

      ref_name, default_tag = PluginHelpers::DockerRef.split(name)
      ref_tag = @params["tag"]? || default_tag
      full_ref = PluginHelpers::DockerRef.join(ref_name, ref_tag)

      client = Docr::Client.new
      api = Docr::API.new(client)

      exists = image_exists?(client, full_ref)

      case state
      when "present"
        if exists
          PluginResult.new(changed: false, failed: false, msg: "Image #{full_ref} already present")
        elsif check_mode
          PluginResult.new(changed: true, failed: false, msg: "Image #{full_ref} would be pulled")
        else
          api.images.create(ref_name, ref_tag)
          PluginResult.new(changed: true, failed: false, msg: "Pulled image #{full_ref}")
        end
      when "absent"
        if !exists
          PluginResult.new(changed: false, failed: false, msg: "Image #{full_ref} already absent")
        elsif check_mode
          PluginResult.new(changed: true, failed: false, msg: "Image #{full_ref} would be removed")
        else
          api.images.delete(full_ref, force: true)
          PluginResult.new(changed: true, failed: false, msg: "Removed image #{full_ref}")
        end
      else
        PluginResult.new(changed: false, failed: true, msg: "state must be 'present' or 'absent', got '#{state}'")
      end
    rescue ex : Docr::Errors::DockerAPIError
      PluginResult.new(changed: false, failed: true, msg: "Docker API error: #{ex.message}")
    rescue ex : Socket::ConnectError
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the Docker daemon (#{docker_host_description}): #{ex.message}")
    end

    # Existence check via a raw GET rather than Images#inspect: we only
    # need a yes/no answer, so there's no reason to pull in (and trust)
    # docr's much larger, less-exercised Docr::Types::Image parse just to
    # throw the result away.
    private def image_exists?(client : Docr::Client, ref : String) : Bool
      # The body must be drained even though its content is unused -
      # otherwise it's left sitting on the shared keep-alive connection and
      # desyncs the HTTP/1.1 framing for whatever call comes next.
      client.call("GET", "/images/#{ref}/json") { |response| response.consume_body_io }
      true
    rescue ex : Docr::Errors::DockerAPIError
      return false if ex.status_code == 404
      raise ex
    end

    private def docker_host_description : String
      ENV["DOCKER_HOST"]? || "default socket #{Docr::Client::DEFAULT_SOCKET_PATH}"
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::DockerImagePlugin.new(config)
plugin.run
