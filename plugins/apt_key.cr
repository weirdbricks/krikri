#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Apt_key plugin - imports/removes a GPG key into apt's legacy trusted
  # keyring. Compatible with Ansible's ansible.builtin.apt_key module
  # (deprecated in real ansible-core in favor of signed-by:/deb822_
  # repository, but still shipped and still what plenty of real roles
  # use - verified against real ansible-playbook, which still runs it
  # successfully on ansible-core 2.19.4).
  #
  # Supported parameters:
  # - url: fetch the key from this URL (fetched on the TARGET, matching
  #   real Ansible - apt_key: is never delegated to the controller the
  #   way copy:'s src: implicitly is)
  # - data: the key's own ASCII-armored text, given directly
  # - state: present (default) | absent
  # - id: the key's ID/fingerprint - required for state: absent, and
  #   used to skip re-adding an already-present key for state: present
  # - validate_certs: default true; false skips TLS verification for
  #   url: (grafana's own role sets this)
  #
  # Not implemented: keyserver: (fetching by ID from a keyserver -
  # real-world usage is overwhelmingly url:/data:, a keyserver round
  # trip is also the flakiest/slowest part of the real module),
  # keyring: (an alternate keyring file - real playbooks essentially
  # always mean the default system one).
  class AptKeyPlugin < BasePlugin
    def execute : PluginResult
      state = @params["state"]?.try(&.downcase) || "present"

      if state == "absent"
        return remove_key
      end

      add_key
    end

    private def add_key : PluginResult
      key_id = @params["id"]?

      if key_id && key_present?(key_id)
        return PluginResult.new(changed: false, failed: false, msg: "Key already present")
      end

      content = if url = @params["url"]?
                  fetch_key(url)
                elsif data = @params["data"]?
                  data
                else
                  return PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: url or data")
                end
      return PluginResult.new(changed: false, failed: true, msg: "Failed to fetch key") unless content

      tmp_path = "/tmp/.crystal-ansible-apt-key-#{Random.rand(100000..999999)}"
      begin
        File.write(tmp_path, content)
        result = remote_exec("apt-key add #{tmp_path}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: "apt-key add failed: #{result[:stderr]}")
        end
      ensure
        File.delete(tmp_path) rescue nil
      end

      PluginResult.new(changed: true, failed: false, msg: "Key added")
    end

    private def remove_key : PluginResult
      key_id = @params["id"]?
      return PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: id") unless key_id

      unless key_present?(key_id)
        return PluginResult.new(changed: false, failed: false, msg: "Key already absent")
      end

      result = remote_exec("apt-key del #{key_id}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "apt-key del failed: #{result[:stderr]}")
      end

      PluginResult.new(changed: true, failed: false, msg: "Key removed")
    end

    private def key_present?(key_id : String) : Bool
      # Real apt-key list output prints each key's fingerprint with
      # spaces every 4 characters - stripping spaces from both sides
      # before comparing so a shortened (e.g. last-8-hex-chars) id: still
      # matches inside the full fingerprint.
      result = remote_exec("apt-key list 2>/dev/null")
      result[:stdout].gsub(" ", "").includes?(key_id.gsub(" ", ""))
    end

    private def fetch_key(url : String, redirects_left : Int32 = 5) : String?
      return nil if redirects_left < 0

      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 15.seconds
      client.read_timeout = 15.seconds

      if !is_true?(@params["validate_certs"]?, default: true) && (tls = client.tls?)
        tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      end

      response = client.get(uri.request_target)

      if response.status.redirection? && (location = response.headers["Location"]?)
        resolved = URI.parse(location).absolute? ? location : uri.resolve(location).to_s
        return fetch_key(resolved, redirects_left - 1)
      end

      return nil unless response.success?
      response.body
    ensure
      client.try(&.close)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::AptKeyPlugin.new(config)
plugin.run
