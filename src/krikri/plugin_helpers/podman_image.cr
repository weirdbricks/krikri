require "json"

module Krikri
  module PluginHelpers
    # PodmanImage - pure logic for the podman_image plugin: image
    # reference construction (the real module's name/tag combination)
    # and creds argument building. Split out so this logic is
    # unit-spec-able (execution needs a real podman host).
    module PodmanImage
      # name may carry its own tag/digest; the separate tag param only
      # applies when the name has none of its own (the real module's
      # image-name split).
      def self.build_reference(name : String, tag : String?) : String
        return name if tag.nil? || tag.empty?
        return name if name.includes?(":") || name.includes?("@")
        "#{name}:#{tag}"
      end

      # --creds argument for pull: "user" alone or "user:password".
      def self.creds_argument(username : String?, password : String?) : String
        return "" if username.nil? || username.empty?
        creds = password && !password.empty? ? "#{username}:#{password}" : username
        " --creds '#{creds.gsub("'", "'\\''")}'"
      end
    end
  end
end
