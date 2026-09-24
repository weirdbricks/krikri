require "json"
require "krikri-xml"
require "../base_plugin"
require "./iam_api"

module Krikri
  module PluginHelpers
    # User-shaping logic for the amazon.aws.iam_user_info plugin - the
    # same split the ec2_*_info modules use (thin plugin binary, logic in
    # a PluginHelpers module spec-testable through the IamApi transport
    # seam; see the plugin binary for the param semantics).
    #
    # Field-path note: the IAM Query API's XML uses the request-style
    # PascalCase names (UserName, Arn, CreateDate, UserId, Path,
    # PasswordLastUsed) - NOT the snake_case keys the real module's
    # result carries. boto3 parses GetUser/ListUsers into those
    # snake_case dicts (its model maps UserName -> user_name etc. for
    # the IAM namespace), so normalization reads the PascalCase wire
    # element and emits the snake_case key.
    module IamUser
      def self.run(params : Hash(String, String)) : Krikri::PluginResult
        name = (params["name"]?.presence || params["user_name"]?.presence)
        group = (params["group"]?.presence || params["group_name"]?.presence)
        path = (params["path_prefix"]?.presence || params["path"]?.presence || params["prefix"]?.presence || "/")

        users = list_users(name, group, path)
        built = Krikri::PluginResult.new(changed: false, failed: false)
        built.extra["iam_users"] = JSON::Any.new(users.map { |user| JSON::Any.new(user) })
        built
      rescue ex : PluginHelpers::IamApi::Error
        Krikri::PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
      rescue ex : PluginHelpers::Ec2Api::Error
        Krikri::PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
      end

      private def self.list_users(name : String?, group : String?, path : String) : Array(Hash(String, JSON::Any))
        iam_users = raw_users(name, group, path)
        iam_users = iam_users.select { |user| PluginHelpers::IamApi.text(user, "UserName") == name } if name

        iam_users.map do |user_node|
          username = PluginHelpers::IamApi.text(user_node, "UserName") || ""
          normalized = normalize_user(user_node)
          normalized["tags"] = JSON::Any.new(user_tags(username))
          normalized["login_profile"] = JSON::Any.new(login_profile(username))
          normalized
        end
      end

      private def self.raw_users(name : String?, group : String?, path : String) : Array(KXML::Element)
        # name but not path/group: the real module goes straight to GetUser.
        return get_user(name) if name && path == "/" && group.nil?
        return group_members(group) if group
        list_users_by_path(path)
      rescue ex : PluginHelpers::IamApi::Error
        # NoSuchEntity (missing user/group) is an empty result in the real
        # module, not a failure; anything else (auth, throttling, ...)
        # surfaces as a real failure.
        raise ex unless ex.message.to_s.includes?("NoSuchEntity")
        [] of KXML::Element
      end

      private def self.get_user(name : String) : Array(KXML::Element)
        user = PluginHelpers::IamApi.call("GetUser", {"UserName" => name})
        user_node = PluginHelpers::IamApi.child(user, "GetUserResult").try { |result| PluginHelpers::IamApi.child(result, "User") }
        user_node ? [user_node] : [] of KXML::Element
      end

      private def self.group_members(group : String) : Array(KXML::Element)
        group_node = PluginHelpers::IamApi.call("GetGroup", {"GroupName" => group})
        return [] of KXML::Element unless result = PluginHelpers::IamApi.child(group_node, "GetGroupResult")
        return [] of KXML::Element unless wrapper = PluginHelpers::IamApi.child(result, "Users")
        PluginHelpers::IamApi.children(wrapper, "member")
      end

      private def self.list_users_by_path(path : String) : Array(KXML::Element)
        users = [] of KXML::Element
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
        users
      end

      private def self.user_tags(username : String) : Hash(String, JSON::Any)
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

      private def self.login_profile(username : String) : Hash(String, JSON::Any)
        profile = PluginHelpers::IamApi.call("GetLoginProfile", {"UserName" => username})
        result_node = PluginHelpers::IamApi.child(profile, "GetLoginProfileResult")
        login = result_node.try { |result| PluginHelpers::IamApi.child(result, "LoginProfile") }
        return {} of String => JSON::Any unless login

        result = {} of String => JSON::Any
        {"UserName" => "user_name", "CreateDate" => "create_date"}.each do |xml_name, key|
          if value = PluginHelpers::IamApi.text(login, xml_name)
            result[key] = JSON::Any.new(iso_datetime(value))
          end
        end
        if value = PluginHelpers::IamApi.text(login, "PasswordResetRequired")
          result["password_reset_required"] = JSON::Any.new(value == "true")
        end
        result
      rescue
        # NoSuchEntity - no console access, the real module's {} shape
        {} of String => JSON::Any
      end

      # boto3 parses IAM's CreateDate/PasswordLastUsed into datetime
      # objects and the real module's JSON encoding renders those with
      # isoformat() (+00:00), not the wire's trailing Z.
      private def self.iso_datetime(text : String) : String
        text.matches?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/) ? text.sub(/Z\z/, "+00:00") : text
      end

      private def self.normalize_user(node : KXML::Element) : Hash(String, JSON::Any)
        result = {} of String => JSON::Any
        {
          "Arn"              => "arn",
          "CreateDate"       => "create_date",
          "PasswordLastUsed" => "password_last_used",
          "Path"             => "path",
          "UserId"           => "user_id",
          "UserName"         => "user_name",
        }.each do |xml_name, key|
          if value = PluginHelpers::IamApi.text(node, xml_name)
            result[key] = JSON::Any.new(iso_datetime(value))
          end
        end
        result
      end
    end
  end
end
