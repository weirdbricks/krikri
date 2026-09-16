#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ec2_api"
require "../src/krikri/plugin_helpers/aws_module_args"
require "../src/krikri/plugin_helpers/aws_module_specs"
require "../src/krikri/plugin_helpers/ec2_info"

module Krikri
  # ec2_vpc_subnet_info plugin (amazon.aws.ec2_vpc_subnet_info) - read-only
  # DescribeSubnets lookup via the EC2 Query API, through the shared
  # signed-request helper PluginHelpers::Ec2Api. See that helper's
  # comment for the credential/region resolution contract (AWS_* env
  # vars, region param fallback).
  #
  # All lookup/shaping logic lives in PluginHelpers::Ec2Info#run_subnets
  # (see that helper's comment); this binary only adapts the BasePlugin
  # plumbing to it.
  #
  # Parameters: subnet_ids (JSON list, alias subnet_id), filters (JSON
  # dict), region.
  class Ec2VpcSubnetInfoPlugin < BasePlugin
    def execute : PluginResult
      if result = PluginHelpers::AwsModuleArgs.validate(PluginHelpers::AwsModuleSpecs::EC2_VPC_SUBNET_INFO, @params)
        return result
      end
      if result = PluginHelpers::AwsModuleArgs.boto3_gate(@params)
        return result
      end
      PluginHelpers::Ec2Info.run_subnets(@params)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::Ec2VpcSubnetInfoPlugin.new(config)
plugin.run
