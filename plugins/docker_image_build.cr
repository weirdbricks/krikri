#!/usr/bin/env crystal

require "json"
require "docr"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/docker_ref"
require "../src/crystal_play/plugin_helpers/docker_client"

module CrystalPlay
  # docker_image_build plugin - builds a Docker image via the `docker
  # buildx build` CLI. Compatible with (a subset of) Ansible's
  # community.docker.docker_image_build module.
  #
  # Unlike docker_image.cr (which talks to the Docker Engine API
  # directly), buildx builds have no API equivalent - real Ansible's own
  # module shells out to the `docker buildx build` CLI too, so this
  # plugin does the same via #remote_exec. Image-existence checking (for
  # the rebuild: never idempotency check) still goes straight to the
  # Engine API, same approach as docker_image.cr.
  #
  # Supported parameters: name (required), tag (default "latest"), path
  # (required), dockerfile, cache_from (list), pull (bool), network,
  # nocache (bool), args (dict, build-args), target, platform (list),
  # labels (dict), rebuild (never (default) / always), check_mode.
  #
  # Not implemented: shm_size, secrets, outputs, etc_hosts - all
  # advanced buildx-output/secret-passing features with no bearing on
  # the common "build an image from a Dockerfile" case.
  class DockerImageBuildPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      return missing_param("name") unless name

      path = @params["path"]?
      return missing_param("path") unless path
      unless remote_dir_exists?(path)
        return PluginResult.new(changed: false, failed: true, msg: "\"#{path}\" is not an existing directory")
      end

      dockerfile = @params["dockerfile"]?
      if dockerfile && !remote_file_exists?(File.join(path, dockerfile))
        return PluginResult.new(changed: false, failed: true, msg: "\"#{File.join(path, dockerfile)}\" is not an existing file")
      end

      ref_name, default_tag = PluginHelpers::DockerRef.split(name)
      tag = @params["tag"]? || default_tag
      rebuild = @params["rebuild"]? || "never"
      check_mode = true?(@params["check_mode"]?)

      client, docker_host_description = PluginHelpers::DockerClient.build(@params)
      existing_image = image_id(client, PluginHelpers::DockerRef.join(ref_name, tag))

      if existing_image && rebuild == "never"
        return PluginResult.new(changed: false, failed: false, msg: "Image #{ref_name}:#{tag} already present")
      end

      return PluginResult.new(changed: true, failed: false, msg: "Would build image #{ref_name}:#{tag} (check mode)") if check_mode

      args = build_args(ref_name, tag, path)
      build_result = remote_exec("docker #{args.join(" ")}")

      unless build_result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "Building #{ref_name}:#{tag} failed", stdout: build_result[:stdout], stderr: build_result[:stderr])
      end

      PluginResult.new(changed: true, failed: false, msg: "Built image #{ref_name}:#{tag}", stdout: build_result[:stdout], stderr: build_result[:stderr])
    rescue ex : Docr::Errors::DockerAPIError
      PluginResult.new(changed: false, failed: true, msg: "Docker API error: #{ex.message}")
    rescue ex : Socket::ConnectError
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the Docker daemon (#{docker_host_description}): #{ex.message}")
    end

    private def build_args(ref_name : String, tag : String, path : String) : Array(String)
      args = ["buildx", "build", "--progress", "plain", "--tag", shell_quote("#{ref_name}:#{tag}")]

      if dockerfile = @params["dockerfile"]?
        args << "--file" << shell_quote(File.join(path, dockerfile))
      end
      each_list_param("cache_from") { |v| args << "--cache-from" << shell_quote(v) }
      args << "--pull" if true?(@params["pull"]?)
      if network = @params["network"]?
        args << "--network" << shell_quote(network)
      end
      args << "--no-cache" if true?(@params["nocache"]?)
      each_dict_param("args") { |k, v| args << "--build-arg" << shell_quote("#{k}=#{v}") }
      if target = @params["target"]?
        args << "--target" << shell_quote(target)
      end
      each_list_param("platform") { |v| args << "--platform" << shell_quote(v) }
      each_dict_param("labels") { |k, v| args << "--label" << shell_quote("#{k}=#{v}") }

      args << "--" << shell_quote(path)
      args
    end

    private def each_list_param(key : String, &)
      raw = @params[key]?
      return unless raw

      values = begin
        JSON.parse(raw).as_a.map(&.as_s)
      rescue
        begin
          Array(String).from_json(raw.gsub('\'', '"'))
        rescue
          [raw]
        end
      end

      values.each { |v| yield v }
    end

    private def each_dict_param(key : String, &)
      raw = @params[key]?
      return unless raw

      hash = begin
        JSON.parse(raw).as_h
      rescue
        return
      end

      hash.each { |k, v| yield k, v.to_s }
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end

    # Same raw-GET, minimal-trust approach as docker_image.cr's own
    # #image_id (see that plugin's doc comment) - nil if the image
    # doesn't exist.
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

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::DockerImageBuildPlugin.new(config)
plugin.run
