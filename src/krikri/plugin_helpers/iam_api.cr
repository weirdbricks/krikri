require "json"
require "http/client"
require "uri"
require "xml"
require "awscr-signer"
require "./ec2_api"

module Krikri
  module PluginHelpers
    # Shared IAM Query API client for the amazon.aws.iam_* plugins.
    #
    # IAM is not EC2: it's a global service (endpoint iam.amazonaws.com,
    # region us-east-1 for signing), its own API version, and its own XML
    # shapes - but the wire pattern is the same SigV4-signed POST of
    # form-encoded `Action=<Name>&Version=2010-05-08&<params>` the Ec2Api
    # helper already speaks for ec2.<region>.amazonaws.com. This helper
    # mirrors that one's shape (including the transport test seam) so the
    # iam_* plugins share one signing/POST/error path. Credentials come
    # from Ec2Api.resolve_credentials - the same environment-variable
    # contract as every other amazon.aws plugin here.
    module IamApi
      IAM_API_VERSION = "2010-05-08"
      IAM_ENDPOINT    = "iam.amazonaws.com"
      SIGNING_REGION  = "us-east-1"

      class Error < Exception
      end

      # Same test seam as Ec2Api: (encoded form body) -> raw XML response
      # body, instead of a real signed HTTP round trip.
      @@transport : Proc(String, String)? = nil

      def self.transport=(proc : Proc(String, String)?) : Nil
        @@transport = proc
      end

      def self.transport? : Proc(String, String)?
        @@transport
      end

      def self.call(action : String, params : Hash(String, String) | Array(Tuple(String, String)) = {} of String => String) : XML::Node
        built = URI::Params.new
        built.add("Action", action)
        built.add("Version", IAM_API_VERSION)
        params.each { |key, value| built.add(key, value) }

        # The transport seam short-circuits credential resolution too -
        # specs have no AWS environment to resolve from.
        if transport = @@transport
          body = transport.call(built.to_s)
        else
          credentials = Ec2Api.resolve_credentials
          body = signed_post(built.to_s, credentials)
        end
        root = XML.parse(body).root
        raise Error.new("IAM #{action}: empty response") unless root

        error = root.children.find { |child| child.name == "Error" }
        if error
          code = error.children.find { |child| child.name == "Code" }.try(&.content) || ""
          message = error.children.find { |child| child.name == "Message" }.try(&.content) || ""
          raise Error.new("IAM #{action}: #{code}: #{message}")
        end
        root
      end

      # A List* action's paginated walk: yields each response root until
      # IsTruncated is false, following Marker. IsTruncated/Marker sit
      # under the action's Result element (not directly under the root),
      # so the search is a descendant walk.
      def self.each_page(action : String, build_params : Proc(String?, Array(Tuple(String, String))), &) : Nil
        marker = nil
        loop do
          root = call(action, build_params.call(marker))
          yield root
          truncated = descendant(root, "IsTruncated").try(&.content) == "true"
          break unless truncated
          marker = descendant(root, "Marker").try(&.content)
          break unless marker
        end
      end

      # Depth-first search for the first element with the given name.
      def self.descendant(node : XML::Node, name : String) : XML::Node?
        node.children.each do |child|
          return child if child.name == name
          if found = descendant(child, name)
            return found
          end
        end
        nil
      end

      def self.child(node : XML::Node, name : String) : XML::Node?
        node.children.find { |child| child.name == name }
      end

      def self.children(node : XML::Node, name : String) : Array(XML::Node)
        node.children.select { |child| child.name == name }
      end

      def self.text(node : XML::Node, name : String) : String?
        child(node, name).try(&.content)
      end

      private def self.signed_post(body : String, credentials : Ec2Api::Credentials) : String
        if transport = @@transport
          return transport.call(body)
        end

        request = HTTP::Request.new("POST", "/", HTTP::Headers{
          "Host"         => IAM_ENDPOINT,
          "Content-Type" => "application/x-www-form-urlencoded",
        }, body)

        signer = Awscr::Signer::Signers::V4.new("iam", SIGNING_REGION, credentials.access_key, credentials.secret_key, credentials.session_token)
        signer.sign(request)

        response = HTTP::Client.post("https://#{IAM_ENDPOINT}/", headers: request.headers, body: body)
        response.body
      end
    end
  end
end
