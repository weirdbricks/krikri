#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ec2_api"
require "../src/krikri/plugin_helpers/ec2_info"

module Krikri
  # ec2_vpc_net_info plugin (amazon.aws.ec2_vpc_net_info) - read-only
  # DescribeVpcs lookup (plus the per-VPC DescribeVpcAttribute DNS
  # attribute calls real Ansible makes) via the EC2 Query API, through
  # the shared signed-request helper PluginHelpers::Ec2Api. See that
  # helper's comment for the credential/region resolution contract
  # (AWS_* env vars, region param fallback).
  #
  # All lookup/shaping logic lives in PluginHelpers::Ec2Info#run_vpcs
  # (see that helper's comment); this binary only adapts the BasePlugin
  # plumbing to it.
  #
  # Parameters: vpc_ids (JSON list, alias vpc_id), filters (JSON dict),
  # region.
  class Ec2VpcNetInfoPlugin < BasePlugin
    def execute : PluginResult
      PluginHelpers::Ec2Info.run_vpcs(@params)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::Ec2VpcNetInfoPlugin.new(config)
plugin.run
