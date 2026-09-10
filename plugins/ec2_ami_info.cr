#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ec2_api"
require "../src/krikri/plugin_helpers/ec2_info"

module Krikri
  # ec2_ami_info plugin (amazon.aws.ec2_ami_info) - read-only
  # DescribeImages lookup (plus the per-image
  # DescribeImageAttribute/launchPermission calls when
  # describe_image_attributes is set) via the EC2 Query API, through the
  # shared signed-request helper PluginHelpers::Ec2Api. See that
  # helper's comment for the credential/region resolution contract
  # (AWS_* env vars, region param fallback).
  #
  # All lookup/shaping logic lives in PluginHelpers::Ec2Info#run_images
  # (see that helper's comment); this binary only adapts the BasePlugin
  # plumbing to it.
  #
  # Parameters: image_ids (JSON list, alias image_id), filters (JSON
  # dict), owners (JSON list, alias owner), executable_users (JSON
  # list), describe_image_attributes (bool), region.
  class Ec2AmiInfoPlugin < BasePlugin
    def execute : PluginResult
      PluginHelpers::Ec2Info.run_images(@params)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::Ec2AmiInfoPlugin.new(config)
plugin.run
