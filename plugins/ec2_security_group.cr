#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ec2_api"
require "../src/krikri/plugin_helpers/ec2_security_group"

module Krikri
  # ec2_security_group plugin (amazon.aws.ec2_security_group) - manage a
  # security group and its ingress/egress rules via the EC2 Query API,
  # through the shared signed-request helper PluginHelpers::Ec2Api. See
  # that helper's comment for the credential/region resolution contract
  # (AWS_* env vars, region param fallback).
  #
  # All decision/execution logic lives in
  # PluginHelpers::Ec2SecurityGroup#run (see that helper's comment);
  # this binary only adapts the BasePlugin plumbing to it.
  #
  # Parameters: name (required), description, vpc_id, rules
  # (JSON list), rules_egress (JSON list), state (present/absent),
  # purge_rules/purge_rules_egress (default true), tags (JSON dict),
  # region, check_mode.
  class Ec2SecurityGroupPlugin < BasePlugin
    def execute : PluginResult
      PluginHelpers::Ec2SecurityGroup.run(@params)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::Ec2SecurityGroupPlugin.new(config)
plugin.run
