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
require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/iam_api"

module Krikri
  class IamUserInfoPlugin < BasePlugin
    def execute : PluginResult
      name = (@params["name"]?.presence || @params["user_name"]?.presence)
      group = (@params["group"]?.presence || @params["group_name"]?.presence)
      path = (@params["path_prefix"]?.presence || @params["path"]?.presence || @params["prefix"]?.presence || "/")

      users = list_users(name, group, path)
      PluginResult.new(changed: false, failed: false, msg: "",
        iam_users: JSON::Any.new(users.map { |user| JSON::Any.new(user) }))
    rescue ex : PluginHelpers::IamApi::Error
      PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
    rescue ex : PluginHelpers::Ec2Api::Error
      PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
    end

    private def list_users(name : String?, group : String?, path : String) : Array(Hash(String, JSON::Any))
      iam_users = raw_users(name, group, path)
      iam_users = iam_users.select { |user| PluginHelpers::IamApi.text(user, "user_name") == name } if name

      iam_users.map do |user_node|
        username = PluginHelpers::IamApi.text(user_node, "user_name") || ""
        normalized = normalize_user(user_node)
        normalized["tags"] = JSON::Any.new(user_tags(username))
        normalized["login_profile"] = JSON::Any.new(login_profile(username))
        normalized
      end
    end

    private def raw_users(name : String?, group : String?, path : String) : Array(XML::Node)
      # name but not path/group: the real module goes straight to GetUser.
      if name && path == "/" && group.nil?
        user = PluginHelpers::IamApi.call("GetUser", {"UserName" => name})
        user_node = PluginHelpers::IamApi.child(user, "GetUserResult").try { |result| PluginHelpers::IamApi.child(result, "User") }
        return user_node ? [user_node] : [] of XML::Node
      end

      users = [] of XML::Node
      if group
        group_node = PluginHelpers::IamApi.call("GetGroup", {"GroupName" => group})
        if result = PluginHelpers::IamApi.child(group_node, "GetGroupResult")
          if wrapper = PluginHelpers::IamApi.child(result, "Users")
            users += PluginHelpers::IamApi.children(wrapper, "member")
          end
        end
      else
        PluginHelpers::IamApi.each_page("ListUsers", ->(marker : String?) do
          params = [{"PathPrefix", path}] of Tuple(String, String)
          params << {"Marker", marker} if marker
          params
        end) do |root|
          if list = PluginHelpers::IamApi.child(root, "ListUsersResult")
            if set = PluginHelpers::IamApi.child(list, "Users")
              users += PluginHelpers::IamApi.children(set, "member")
            end
          end
        end
      end
      users
    rescue ex : PluginHelpers::IamApi::Error
      # NoSuchEntity (missing user/group) is an empty result in the real
      # module, not a failure; anything else (auth, throttling, ...)
      # surfaces as a real failure.
      raise ex unless ex.message.to_s.includes?("NoSuchEntity")
      [] of XML::Node
    end

    private def user_tags(username : String) : Hash(String, JSON::Any)
      tags = Hash(String, JSON::Any).new
      begin
        PluginHelpers::IamApi.each_page("ListUserTags", ->(marker : String?) do
          params = [{"UserName", username}] of Tuple(String, String)
          params << {"Marker", marker} if marker
          params
        end) do |root|
          if result = PluginHelpers::IamApi.child(root, "ListUserTagsResult")
            if tag_set = PluginHelpers::IamApi.child(result, "Tags")
              PluginHelpers::IamApi.children(tag_set, "member").each do |member|
                key = PluginHelpers::IamApi.text(member, "Key")
                value = PluginHelpers::IamApi.text(member, "Value")
                next if key.nil? || key.empty?
                tags[key] = JSON::Any.new(value || "")
              end
            end
          end
        end
      rescue
      end
      tags
    end

    private def login_profile(username : String) : Hash(String, JSON::Any)
      profile = PluginHelpers::IamApi.call("GetLoginProfile", {"UserName" => username})
      login = PluginHelpers::IamApi.child(profile, "LoginProfile")
      return {} of String => JSON::Any unless login

      result = {} of String => JSON::Any
      {"create_date", "password_reset_required", "user_name"}.each do |field|
        if value = PluginHelpers::IamApi.text(login, field)
          result[field] = JSON::Any.new(value)
        end
      end
      result
    rescue
      # NoSuchEntity - no console access, the real module's {} shape
      {} of String => JSON::Any
    end

    private def normalize_user(node : XML::Node) : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      {
        "arn"                => "arn",
        "create_date"        => "create_date",
        "password_last_used" => "password_last_used",
        "path"               => "path",
        "user_id"            => "user_id",
        "user_name"          => "user_name",
      }.each do |xml_name, key|
        if value = PluginHelpers::IamApi.text(node, xml_name)
          result[key] = JSON::Any.new(value)
        end
      end
      result
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::IamUserInfoPlugin.new(config)
plugin.run
