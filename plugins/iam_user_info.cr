#!/usr/bin/env crystal
# amazon.aws.iam_user_info - gathers IAM user facts over the signed IAM
# Query API (no boto3; same direct-API contract as the other amazon.aws
# plugins here - see plugins/ec2_key.cr and
# src/krikri/plugin_helpers/ec2_api.cr). Ported from amazon.aws's
# iam_user_info module (round 300141: deekayen.iam_access_simulation
# uses it; previously unavailable -> rc=4 "unavailable modules").
#
# Semantics matching the real module (pure read, never changed):
# - name (user_name alias) + default path_prefix + no group ->
#   GetUser; a missing user is an empty result, not a failure.
# - group (group_name alias) -> the group's member list (GetGroup),
#   optionally filtered by name; a missing group yields nothing.
# - otherwise -> ListUsers under path_prefix (path/prefix aliases),
#   paginated; name filters the result when a group/path was given.
# - Every returned user carries its ListUserTags tags and a
#   GetLoginProfile login_profile ({} when the user has no console
#   access), and is normalized to snake_case keys (user_name, user_id,
#   arn, create_date, password_last_used, path, tags, login_profile).
# - Returns iam_users.
#
# All lookup/shaping logic lives in PluginHelpers::IamUser (see that
# helper's comment for the wire field-path notes); this binary only
# adapts the BasePlugin plumbing to it.
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/iam_api"
require "../src/krikri/plugin_helpers/aws_module_args"
require "../src/krikri/plugin_helpers/aws_module_specs"
require "../src/krikri/plugin_helpers/iam_user"

module Krikri
  class IamUserInfoPlugin < BasePlugin
    def execute : PluginResult
      if result = PluginHelpers::AwsModuleArgs.validate(PluginHelpers::AwsModuleSpecs::IAM_USER_INFO, @params)
        return result
      end
      if result = PluginHelpers::AwsModuleArgs.boto3_gate(@params)
        return result
      end
      PluginHelpers::IamUser.run(@params)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::IamUserInfoPlugin.new(config)
plugin.run
