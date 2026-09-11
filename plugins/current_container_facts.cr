#!/usr/bin/env crystal
# community.docker.current_container_facts - detects whether the module
# runs inside a Docker/Podman container and sets facts. Ported from
# community.docker's current_container_facts module (round 300010:
# collivier.xtesting uses it; previously unavailable -> rc=4
# "unavailable modules").
#
# Detection is the real module's best-effort chain, local to wherever
# the plugin process runs (the target):
# - /proc/self/cpuset: /docker/<id> -> docker, /azpl_job/<id> ->
#   azure_pipelines, /actions_job/<id> -> github_actions
# - /proc/self/mountinfo fallback (cgroupv2-era Docker/Podman): a
#   64-hex-char id preceding /etc/hostname in a mount root - docker,
#   or .../<id>/userdata/hostname for podman.
#
# Pure read, never changed; sets ansible_module_running_in_container,
# ansible_module_container_id, ansible_module_container_type.
require "json"
require "../src/krikri/base_plugin"

module Krikri
  class CurrentContainerFactsPlugin < BasePlugin
    def execute : PluginResult
      container_id = ""
      container_type = ""

      cpuset = read_file("/proc/self/cpuset")
      if cpuset
        cgroup_path, cgroup_name = cpuset.strip.rpartition("/")[0], cpuset.strip.rpartition("/")[2]

        case cgroup_path
        when "/docker"      then container_id, container_type = cgroup_name, "docker"
        when "/azpl_job"    then container_id, container_type = cgroup_name, "azure_pipelines"
        when "/actions_job" then container_id, container_type = cgroup_name, "github_actions"
        end
      end

      if container_id.empty? && (mountinfo = read_file("/proc/self/mountinfo"))
        mountinfo.each_line do |line|
          parts = line.split
          next unless parts.size >= 5 && parts[4] == "/etc/hostname"
          if m = /.*\/([a-f0-9]{64})\/hostname$/.match(parts[3])
            container_id, container_type = m[1], "docker"
          end
          if m = /.*\/([a-f0-9]{64})\/userdata\/hostname$/.match(parts[3])
            container_id, container_type = m[1], "podman"
          end
        end
      end

      facts = {
        "ansible_module_running_in_container" => JSON::Any.new(container_id != ""),
        "ansible_module_container_id"         => JSON::Any.new(container_id),
        "ansible_module_container_type"       => JSON::Any.new(container_type),
      }
      PluginResult.new(changed: false, failed: false, msg: "", ansible_facts: JSON::Any.new(facts))
    end

    private def read_file(path : String) : String?
      return File.read(path) if local_connection? || File.exists?(path)
      result = remote_exec("cat '#{path}' 2>/dev/null")
      result[:exit_code] == 0 && !result[:stdout].empty? ? result[:stdout] : nil
    rescue
      nil
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::CurrentContainerFactsPlugin.new(config)
plugin.run
