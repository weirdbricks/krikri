require "json"
require "xml"
require "../base_plugin"

module Krikri
  module PluginHelpers
    # Read-only lookup logic for the amazon.aws EC2 Describe* info modules
    # (ec2_vpc_subnet_info, ec2_vpc_net_info, ec2_ami_info) through the
    # shared PluginHelpers::Ec2Api signed-request helper - see that
    # helper's comment for the credential/region resolution contract
    # (AWS_* env vars, region param fallback). No state/idempotency: each
    # run is one Describe call (plus, for VPCs and AMIs, the same
    # per-result attribute calls real Ansible makes) with the result list
    # shaped the way the real modules shape it.
    #
    # Result shaping parity: the real modules pass the whole boto3 item
    # through camel_dict_to_snake_dict (so every CamelCase response key
    # becomes snake_case, nested sets included), add an `id` key for
    # backwards compatibility (subnets/VPCs), and overwrite `tags` with
    # a tag-key -> tag-value dict. The generic XML converter here
    # reproduces exactly that from the EC2 XML wire format: element
    # names are camel_to_snake'd, `<item>`-repeated sets become lists,
    # and tagSet becomes the tags dict.
    module Ec2Info
      # -- param parsing ---------------------------------------------------

      # The filters param arrives as a JSON dict string of AWS filter
      # name -> value or list of values (the same string-hash the plugin
      # binary receives), e.g. {"tag:Name": "web"} or
      # {"vpc-id": ["vpc-1", "vpc-2"]}.
      def self.parse_filters(raw : String?) : Array(Tuple(String, Array(String)))
        return [] of Tuple(String, Array(String)) if raw.nil? || raw.empty?
        parsed = JSON.parse(raw)
        return [] of Tuple(String, Array(String)) unless parsed.as_h?

        parsed.as_h.compact_map do |name, value|
          values = if list = value.as_a?
                     list.compact_map do |entry|
                       text = entry.as_s? || entry.to_s
                       text.empty? ? nil : text
                     end
                   else
                     text = value.as_s? || value.to_s
                     text.empty? ? [] of String : [text]
                   end
          next if name.empty? || values.empty?
          {name, values}
        end
      rescue
        [] of Tuple(String, Array(String))
      end

      # List params (subnet_ids, vpc_ids, image_ids, owners,
      # executable_users) arrive as JSON list strings; a bare scalar is
      # accepted too (real Ansible's list type coerces one, and roles
      # write `subnet_ids: subnet-00112233`).
      def self.string_list(raw : String?) : Array(String)
        return [] of String if raw.nil? || raw.empty?
        parsed = JSON.parse(raw)
        if list = parsed.as_a?
          list.compact_map do |entry|
            text = entry.as_s? || entry.to_s
            text.empty? ? nil : text
          end
        else
          text = parsed.as_s? || parsed.to_s
          text.empty? ? [] of String : [text]
        end
      rescue
        [] of String
      end

      # -- generic Describe-result shaping ---------------------------------

      # ansible's camel_dict_to_snake_dict, applied to XML element names.
      # Handles the acronym runs boto responses contain (DnsSupport,
      # Ipv6CidrBlock, EnaSupport) the same way Ansible's regexes do.
      def self.camel_to_snake(name : String) : String
        name.gsub(/([A-Z]+)([A-Z][a-z])/) { "#{$1}_#{$2}" }
          .gsub(/([a-z\d])([A-Z])/) { "#{$1}_#{$2}" }
          .downcase
      end

      # One EC2 XML response element -> the JSON::Any boto3 would have
      # returned and camel_dict_to_snake_dict would have shaped: leaf
      # elements become strings, `<item>`-repeated sets become arrays,
      # tagSet becomes the tags dict, everything else becomes an object
      # with camel_to_snake'd keys.
      def self.jsonify(node : XML::Node) : JSON::Any
        if node.name == "tagSet"
          tags = Hash(String, JSON::Any).new
          Ec2Api.children(node, "item").each do |item|
            key = Ec2Api.text(item, "key")
            next if key.nil? || key.empty?
            tags[key] = JSON::Any.new(Ec2Api.text(item, "value") || "")
          end
          return JSON::Any.new(tags)
        end

        elements = node.children.select(&.element?)
        # Leaf elements: EC2 serializes booleans as lowercase true/false
        # and boto3 parses them into real bools before Ansible's
        # camel_dict_to_snake_dict ever sees them, so the same leaf-text
        # coercion happens here.
        if elements.empty?
          content = node.content.strip
          return JSON::Any.new(true) if content == "true"
          return JSON::Any.new(false) if content == "false"
          return JSON::Any.new(content)
        end
        if elements.all? { |child| child.name == "item" }
          return JSON::Any.new(elements.map { |item| jsonify(item) })
        end

        object = Hash(String, JSON::Any).new
        elements.each do |child|
          # The XML wire names differ from the boto3 keys the real
          # modules' camel_dict_to_snake_dict output carries: tagSet is
          # Tags in boto3 (and the module overwrites it with the tag
          # dict), the image item's blockDeviceMapping is
          # BlockDeviceMappings, and the image item's imageState/
          # imageOwnerId drop their image prefix in boto3 (State/
          # ImageOwnerId -> state/owner_id).
          key = case child.name
                when "tagSet"             then "tags"
                when "blockDeviceMapping" then "block_device_mappings"
                when "imageState"         then "state"
                when "imageOwnerId"       then "owner_id"
                else                           camel_to_snake(child.name)
                end
          object[key] = jsonify(child)
        end
        JSON::Any.new(object)
      end

      # -- shared run helpers -----------------------------------------------

      private def self.numbered_params(values : Array(String), prefix : String) : Array(Tuple(String, String))
        values.each_with_index.map { |value, index| {"#{prefix}.#{index + 1}", value} }.to_a
      end

      private def self.bool_param(raw : String?) : Bool
        raw == "true" || raw == "True" || raw == "yes"
      end

      private def self.result(key : String, entries : Array(JSON::Any)) : Krikri::PluginResult
        built = Krikri::PluginResult.new(changed: false, failed: false, msg: "#{entries.size} found")
        built.extra[key] = JSON::Any.new(entries)
        built
      end

      # -- ec2_vpc_subnet_info -----------------------------------------------

      def self.run_subnets(params : Hash(String, String)) : Krikri::PluginResult
        region = Ec2Api.resolve_region(params["region"]?)
        credentials = Ec2Api.resolve_credentials

        wire = numbered_params(string_list(params["subnet_ids"]?), "SubnetId") +
               Ec2Api.filter_params(parse_filters(params["filters"]?))
        root = Ec2Api.call(region, "DescribeSubnets", Ec2Api.to_form_params(wire), credentials)

        subnets = Ec2Api.items(root, "subnetSet").map do |item|
          subnet = jsonify(item)
          if object = subnet.as_h?
            object["id"] = object["subnet_id"] if object["subnet_id"]?
          end
          subnet
        end
        result("subnets", subnets)
      rescue ex : Ec2Api::Error
        Krikri::PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
      end

      # -- ec2_vpc_net_info ---------------------------------------------------

      def self.run_vpcs(params : Hash(String, String)) : Krikri::PluginResult
        region = Ec2Api.resolve_region(params["region"]?)
        credentials = Ec2Api.resolve_credentials

        wire = numbered_params(string_list(params["vpc_ids"]?), "VpcId") +
               Ec2Api.filter_params(parse_filters(params["filters"]?))
        root = Ec2Api.call(region, "DescribeVpcs", Ec2Api.to_form_params(wire), credentials)

        vpcs = Ec2Api.items(root, "vpcSet").map do |item|
          vpc = jsonify(item)
          next vpc unless object = vpc.as_h?
          vpc_id = object["vpc_id"]?.try(&.as_s?) || ""

          # Real Ansible describes the two DNS attributes per VPC and
          # only sets the keys when the attribute call succeeded.
          ["enableDnsSupport", "enableDnsHostnames"].each do |attribute|
            attr_params = [{"VpcId.1", vpc_id}, {"Attribute", attribute}]
            attr_root = Ec2Api.call(region, "DescribeVpcAttribute", Ec2Api.to_form_params(attr_params), credentials)
            if wrapper = Ec2Api.child(attr_root, attribute)
              if value = Ec2Api.text(wrapper, "value")
                object[camel_to_snake(attribute)] = JSON::Any.new(value == "true")
              end
            end
          end

          object["id"] = object["vpc_id"] if object["vpc_id"]?
          vpc
        end
        result("vpcs", vpcs)
      rescue ex : Ec2Api::Error
        Krikri::PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
      end

      # -- ec2_ami_info ---------------------------------------------------------

      def self.run_images(params : Hash(String, String)) : Krikri::PluginResult
        region = Ec2Api.resolve_region(params["region"]?)
        credentials = Ec2Api.resolve_credentials

        filters = parse_filters(params["filters"]?)
        wire = numbered_params(string_list(params["image_ids"]?), "ImageId") +
               numbered_params(string_list(params["executable_users"]?), "ExecutableUser")

        # Real module's owner optimization: numeric account IDs become an
        # owner-id filter (much faster than the Owners param), "self"
        # must stay an Owners param (not a valid owner-alias filter), and
        # anything else becomes an owner-alias filter.
        owner_n = 0
        owner_param_n = 0
        string_list(params["owners"]?).each do |owner|
          case
          when owner.matches?(/\A\d+\z/)
            key = "owner-id"
            if existing = filters.find { |(name, _)| name == key }
              existing[1] << owner
            else
              filters << {key, [owner]}
            end
          when owner == "self"
            owner_param_n += 1
            wire << {"Owner.#{owner_param_n}", owner}
          else
            key = "owner-alias"
            if existing = filters.find { |(name, _)| name == key }
              existing[1] << owner
            else
              filters << {key, [owner]}
            end
          end
          owner_n += 1
        end

        wire += Ec2Api.filter_params(filters)
        root = Ec2Api.call(region, "DescribeImages", Ec2Api.to_form_params(wire), credentials)

        images = Ec2Api.items(root, "imagesSet").map { |item| jsonify(item) }

        if bool_param(params["describe_image_attributes"]?)
          images = images.map do |image|
            describe_launch_permissions(region, credentials, image)
          end
        end

        # Real module sorts by creation_date (possibly missing).
        images = images.sort_by { |image| image["creation_date"]?.try(&.as_s?) || "" }
        result("images", images)
      rescue ex : Ec2Api::Error
        Krikri::PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
      end

      # launchPermission attribute call per image when
      # describe_image_attributes is set. Describing launch permissions
      # of images owned by others is not permitted and real Ansible
      # treats that as non-fatal - any attribute-call failure here just
      # leaves the image without launch_permissions rather than failing
      # the whole read-only lookup.
      private def self.describe_launch_permissions(region : String, credentials : Ec2Api::Credentials, image : JSON::Any) : JSON::Any
        image_id = image["image_id"]?.try(&.as_s?) || ""
        unless image_id.empty?
          params = [{"ImageId.1", image_id}, {"Attribute", "launchPermission"}]
          root = Ec2Api.call(region, "DescribeImageAttribute", Ec2Api.to_form_params(params), credentials)
          if object = image.as_h?
            if permission_set = Ec2Api.child(root, "launchPermissionSet")
              permissions = Ec2Api.children(permission_set, "item").map { |item| jsonify(item) }
              object["launch_permissions"] = JSON::Any.new(permissions)
            end
          end
        end
        image
      rescue ex : Ec2Api::Error
        image
      end
    end
  end
end
