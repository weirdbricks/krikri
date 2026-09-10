require "json"
require "http/client"
require "uri"
require "xml"
require "awscr-signer"

module Krikri
  module PluginHelpers
    # Shared EC2 Query API client for the amazon.aws.* cloud plugins
    # (ec2_key, ec2_security_group, ec2_instance, the *_info lookups).
    #
    # Every module in the cluster is the same wire pattern the aws_ec2
    # inventory plugin (inventory_plugins.cr) already speaks: a SigV4-signed
    # POST of form-encoded `Action=<Name>&Version=2016-11-15&<params>` to
    # `ec2.<region>.amazonaws.com`, with the XML response body parsed on
    # the way back. This helper wraps exactly that so the six plugins
    # share one signing/POST/error path instead of six copies.
    #
    # Credentials resolve from the same environment variables the aws_ec2
    # inventory plugin reads (AWS_ACCESS_KEY_ID/AWS_ACCESS_KEY,
    # AWS_SECRET_ACCESS_KEY/AWS_SECRET_KEY, AWS_SESSION_TOKEN/
    # AWS_SECURITY_TOKEN); region comes from the module's own `region`
    # param first, then AWS_REGION/AWS_DEFAULT_REGION - the same fallback
    # chain the inventory plugin uses.
    #
    # The plugins run wherever krikri-playbook executes their task (the
    # target host, or locally for ansible_connection=local /
    # delegate_to: localhost), so the credentials must be present in that
    # process's environment - same contract real Ansible's aws modules
    # have, just without the boto profile machinery.
    module Ec2Api
      EC2_API_VERSION = "2016-11-15"

      class Error < Exception
      end

      record Credentials, access_key : String, secret_key : String, session_token : String?

      # Test seam: when set, every request is routed through this proc
      # (region, encoded form body) -> raw XML response body, instead of
      # a real signed HTTP round trip. Specs use it to feed canned XML
      # and assert on the exact form bodies the plugins send.
      @@transport : Proc(String, String, String)? = nil

      def self.transport=(proc : Proc(String, String, String)?) : Nil
        @@transport = proc
      end

      def self.transport? : Proc(String, String, String)?
        @@transport
      end

      def self.resolve_region(param : String?) : String
        region = if param && !param.empty?
                   param
                 else
                   ENV["AWS_REGION"]? || ENV["AWS_DEFAULT_REGION"]?
                 end
        if region.nil? || region.empty?
          raise Error.new("no AWS region specified (set the region parameter, AWS_REGION, or AWS_DEFAULT_REGION)")
        end
        region
      end

      def self.resolve_credentials : Credentials
        access_key = ENV["AWS_ACCESS_KEY_ID"]? || ENV["AWS_ACCESS_KEY"]?
        secret_key = ENV["AWS_SECRET_ACCESS_KEY"]? || ENV["AWS_SECRET_KEY"]?
        unless access_key && secret_key
          raise Error.new("AWS credentials not found (set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY)")
        end
        session_token = ENV["AWS_SESSION_TOKEN"]? || ENV["AWS_SECURITY_TOKEN"]?
        Credentials.new(access_key, secret_key, session_token)
      end

      # One signed EC2 Query API call. *params* is the flat form body
      # (Action/Version added here unless already present); returns the
      # parsed XML document root. Raises Error on HTTP failure - the EC2
      # API's own <Errors><Error><Message> text is surfaced when present.
      def self.call(region : String, action : String, params : URI::Params, credentials : Credentials) : XML::Node
        params.add("Action", action) unless params.has_key?("Action")
        params.add("Version", EC2_API_VERSION) unless params.has_key?("Version")

        body = signed_post(region, params.to_s, credentials)
        root = XML.parse(body).root
        raise Error.new("EC2 #{action}: empty response") unless root
        root
      end

      # Convenience wrapper: resolve everything, one call, flat params.
      def self.call(region : String?, action : String, params : Hash(String, String) | Array(Tuple(String, String))) : XML::Node
        credentials = resolve_credentials
        resolved_region = resolve_region(region)
        call(resolved_region, action, to_form_params(params), credentials)
      end

      def self.to_form_params(params : Hash(String, String) | Array(Tuple(String, String))) : URI::Params
        built = URI::Params.new
        each_param(params) do |key, value|
          built.add(key, value)
        end
        built
      end

      private def self.each_param(params : Hash(String, String) | Array(Tuple(String, String)), & : String, String -> Nil) : Nil
        case params
        when Hash(String, String)         then params.each { |key, value| yield key, value }
        when Array(Tuple(String, String)) then params.each { |(key, value)| yield key, value }
        end
      end

      # Flat key/value pairs a mutating call should issue - one entry per
      # wire parameter, repeated keys allowed (SecurityGroupId.N,
      # Tag.N.Key/Value, ...). The decision helpers each module's logic
      # lives in produce these; the plugin binaries execute them in order.
      record Step, action : String, params : Array(Tuple(String, String))

      # -- XML navigation ------------------------------------------------

      # First direct child element with the given name (EC2 XML responses
      # are namespace-qualified; XML::Node#name in Crystal strips the
      # namespace prefix, so plain-name comparison is what the aws_ec2
      # inventory plugin already relies on).
      def self.child(node : XML::Node, name : String) : XML::Node?
        node.children.find { |child| child.name == name }
      end

      # All direct child elements with the given name - for the repeated
      # <item> elements of response sets (reservationSet, ipPermissionsSet,
      # tagSet, ...).
      def self.children(node : XML::Node, name : String) : Array(XML::Node)
        node.children.select { |child| child.name == name }
      end

      # child(...).content, nil when the element is missing; empty string
      # normalized to nil (EC2 omits optional elements rather than sending
      # empty ones, but belt-and-suspenders costs nothing).
      def self.text(node : XML::Node, name : String) : String?
        child(node, name).try(&.content)
      end

      # A response set's <item> children - e.g. reservationSet/item,
      # ipPermissionsSet/item, tagSet/item.
      def self.items(node : XML::Node, set_name : String) : Array(XML::Node)
        set = child(node, set_name) || return [] of XML::Node
        children(set, "item")
      end

      # tagSet items -> {"Name" => "web", ...}
      def self.parse_tags(node : XML::Node) : Hash(String, String)
        tags = Hash(String, String).new
        items(node, "tagSet").each do |item|
          key = text(item, "key")
          next if key.nil? || key.empty?
          tags[key] = text(item, "value") || ""
        end
        tags
      end

      # -- request builders ----------------------------------------------

      # Filter.N.Name / Filter.N.Value.M pairs - one filter name with one
      # or more values, numbered from 1 in call order.
      def self.filter_params(filters : Array(Tuple(String, Array(String)))) : Array(Tuple(String, String))
        pairs = [] of Tuple(String, String)
        filters.each_with_index do |(name, values), index|
          n = index + 1
          pairs << {"Filter.#{n}.Name", name}
          values.each_with_index do |value, value_index|
            pairs << {"Filter.#{n}.Value.#{value_index + 1}", value}
          end
        end
        pairs
      end

      # Tag.N.Key / Tag.N.Value pairs (CreateTags/DeleteTags shape).
      def self.tag_params(tags : Hash(String, String)) : Array(Tuple(String, String))
        pairs = [] of Tuple(String, String)
        tags.each_with_index do |(key, value), index|
          n = index + 1
          pairs << {"Tag.#{n}.Key", key}
          pairs << {"Tag.#{n}.Value", value}
        end
        pairs
      end

      # -- transport -------------------------------------------------------

      private def self.signed_post(region : String, body : String, credentials : Credentials) : String
        if transport = @@transport
          return transport.call(region, body)
        end

        host = "ec2.#{region}.amazonaws.com"
        request = HTTP::Request.new("POST", "/", HTTP::Headers{
          "Host"         => host,
          "Content-Type" => "application/x-www-form-urlencoded",
        }, body)

        signer = Awscr::Signer::Signers::V4.new("ec2", region, credentials.access_key, credentials.secret_key, credentials.session_token)
        signer.sign(request)

        response = HTTP::Client.new(host, tls: true).exec(request)
        unless response.status.success?
          message = response_message(response.body)
          raise Error.new("EC2 request failed: HTTP #{response.status.code}: #{message || response.body[0, 500]}")
        end

        response.body
      end

      # Pull the human-readable <Message> out of an EC2 error response -
      # the API returns HTTP 4xx with an XML body like
      # <ErrorResponse><Errors><Error><Code>...</Code><Message>...</Message>.
      def self.response_message(body : String) : String?
        root = XML.parse(body).root || return nil
        error = child(root, "Errors")
        error = root unless error
        item = child(error, "Error") || return nil
        message = text(item, "message") || text(item, "Message")
        code = text(item, "code") || text(item, "Code")
        return "#{code}: #{message}" if code && message
        message
      rescue
        nil
      end
    end
  end
end
