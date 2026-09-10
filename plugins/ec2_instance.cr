#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ec2_api"
require "../src/krikri/plugin_helpers/ec2_instance"

module Krikri
  # ec2_instance plugin (amazon.aws.ec2_instance) - manage EC2 instance
  # lifecycle (create/start/stop/restart/terminate) via the EC2 Query
  # API, through the shared signed-request helper PluginHelpers::Ec2Api.
  # See that helper's comment for the credential/region resolution
  # contract (AWS_* env vars, region param fallback).
  #
  # All decision/execution logic lives in PluginHelpers::Ec2Instance#run
  # (see that helper's comment); this binary only adapts the BasePlugin
  # plumbing to it.
  #
  # Parameters: name (Name tag) or instance_ids (JSON list), image_id,
  # instance_type, key_name, security_group/security_groups,
  # vpc_subnet_id, tags (JSON dict), state
  # (present/running/stopped/restarted/terminated/absent), count,
  # exact_count, filters (JSON dict), wait, wait_timeout, user_data,
  # purge_tags, region, check_mode.
  class Ec2InstancePlugin < BasePlugin
    def execute : PluginResult
      PluginHelpers::Ec2Instance.run(@params)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::Ec2InstancePlugin.new(config)
plugin.run
