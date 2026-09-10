#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ec2_api"
require "../src/krikri/plugin_helpers/ec2_key"

module Krikri
  # ec2_key plugin (amazon.aws.ec2_key) - manage an EC2 SSH key pair via
  # the EC2 Query API (CreateKeyPair/ImportKeyPair/DeleteKeyPair/
  # DescribeKeyPairs), through the shared signed-request helper
  # PluginHelpers::Ec2Api. See that helper's comment for the credential/
  # region resolution contract (AWS_* env vars, region param fallback).
  #
  # Unlike most plugins this one runs its work against the AWS API from
  # wherever the task executes - roles typically pair it with
  # delegate_to: localhost or ansible_connection=local, since the AWS
  # credentials must be in the executing process's environment.
  #
  # All decision/execution logic lives in PluginHelpers::Ec2Key#run (see
  # that helper's comment); this binary only adapts the BasePlugin
  # plumbing to it.
  #
  # Parameters: name (required), key_material (public key to import),
  # state (present/absent, default present), force, tags (JSON dict),
  # region, check_mode.
  class Ec2KeyPlugin < BasePlugin
    def execute : PluginResult
      PluginHelpers::Ec2Key.run(@params)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::Ec2KeyPlugin.new(config)
plugin.run
