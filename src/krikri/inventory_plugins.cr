require "yaml"
require "json"
require "xml"
require "http/client"
require "uri"
require "awscr-signer"
require "./vault"
require "./host"
require "./conditional_evaluator"
require "./variable_substitutor/expression_evaluator"

module Krikri
  # YAML-defined inventory plugins (`plugin: <name>` at the top level of an
  # inventory YAML file), the format real Ansible uses for both its built-in
  # sources (`host_list`, `constructed`, `ini`, `yaml`) and collection
  # plugins (`amazon.aws.aws_ec2`).
  #
  # Detection is by the top-level `plugin` key, same as real Ansible. The
  # collection prefix is stripped ("amazon.aws.aws_ec2" dispatches on
  # "aws_ec2"), so a plugin from any collection whose final segment matches
  # a supported name is handled here.
  #
  # aws_ec2 talks to the real EC2 API with SigV4-signed HTTP (via
  # awscr-signer) rather than shelling out to the `aws` CLI: real Ansible
  # only needs boto3 on the controller, and this needs nothing but the two
  # credential environment variables. The DescribeInstances response is
  # parsed from XML and mapped to hosts, then run through the same
  # constructed-style option machinery (compose/keyed_groups/groups/filters)
  # that the aws_ec2 plugin is itself built on in real Ansible - which is
  # also what the standalone `constructed` plugin uses.
  class InventoryPlugins
    SUPPORTED_PLUGINS = %w[host_list ini yaml constructed aws_ec2]

    # The plugin name a YAML inventory document dispatches on, with any
    # collection prefix stripped; nil when the document is not a plugin
    # source (no top-level `plugin` key).
    def self.plugin_name(doc : YAML::Any) : String?
      hash = doc.as_h? || return nil
      plugin = hash["plugin"]?.try(&.as_s?) || return nil
      plugin.split(".").last
    end

    # True when *path* is a YAML inventory source whose plugin is
    # `constructed`. Used by directory parsing: constructed sources do not
    # contribute hosts themselves, they transform hosts contributed by the
    # OTHER sources in the same directory, so they must be applied after
    # every other source is merged (real Ansible behaves the same way).
    def self.constructed_source?(path : String) : Bool
      return false unless path.ends_with?(".yml") || path.ends_with?(".yaml")
      doc = YAML.parse(File.read(path))
      plugin_name(doc) == "constructed"
    rescue
      false
    end

    def self.parse_plugin(path : String, doc : YAML::Any, name : String, existing : Inventory? = nil) : Inventory
      case name
      when "host_list"
        parse_host_list_plugin(doc)
      when "ini"
        InventoryParser.parse_ini(path)
      when "constructed"
        apply_constructed_options(existing || Inventory.new, doc)
      when "aws_ec2"
        parse_aws_ec2(path, doc)
      else
        raise "Inventory plugin '#{name}' is not supported (supported: #{SUPPORTED_PLUGINS.join(", ")})"
      end
    end

    # `plugin: host_list` - a literal list of hosts, comma-separated string
    # or YAML array, each entry going through the same range expansion as
    # an INI host line (`web[01:03]` -> web01 web02 web03).
    private def self.parse_host_list_plugin(doc : YAML::Any) : Inventory
      inventory = Inventory.new

      entries = if raw = doc["hosts"]?
                  if str = raw.as_s?
                    str.split(',')
                  elsif arr = raw.as_a?
                    arr.compact_map(&.as_s?)
                  else
                    [] of String
                  end
                else
                  [] of String
                end

      entries.each do |entry|
        entry = entry.strip
        next if entry.empty?

        InventoryParser.expand_host_range(entry).each do |hostname|
          host = Host.new(hostname)
          inventory.add_host(host)
          inventory.get_or_create_group("all").add_host(host)
          inventory.get_or_create_group("ungrouped").add_host(host)
        end
      end

      inventory
    end

    # `plugin: aws_ec2` - query the EC2 API for instances and turn each
    # into an inventory host. Credentials and region come from the plugin
    # options or the standard AWS environment variables.
    private def self.parse_aws_ec2(path : String, doc : YAML::Any) : Inventory
      regions = ec2_regions(doc)
      access_key = ENV["AWS_ACCESS_KEY_ID"]? || ENV["AWS_ACCESS_KEY"]?
      secret_key = ENV["AWS_SECRET_ACCESS_KEY"]? || ENV["AWS_SECRET_KEY"]?
      unless access_key && secret_key
        raise "aws_ec2 inventory '#{path}': AWS credentials not found (set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY)"
      end
      session_token = ENV["AWS_SESSION_TOKEN"]? || ENV["AWS_SECURITY_TOKEN"]?

      inventory = Inventory.new
      regions.each do |region|
        xml = ec2_describe_instances(region, doc, access_key, secret_key, session_token)
        build_aws_ec2_hosts(inventory, xml, doc, region)
      end

      apply_constructed_options(inventory, doc)
      inventory
    end

    private def self.ec2_regions(doc : YAML::Any) : Array(String)
      if raw = doc["regions"]?
        regions = raw.as_a?.try(&.map(&.as_s)) || [raw.as_s]
        return regions.reject(&.empty?)
      end

      region = ENV["AWS_REGION"]? || ENV["AWS_DEFAULT_REGION"]?
      raise "aws_ec2 inventory: no region specified (set the regions: option, AWS_REGION, or AWS_DEFAULT_REGION)" unless region
      [region]
    end

    # One signed DescribeInstances call per region. Filters from the
    # plugin options are passed through in boto3 form ("tag:Name=web")
    # as Filter.N.Name/Filter.N.Value.M query parameters.
    private def self.ec2_describe_instances(region : String, doc : YAML::Any, access_key : String, secret_key : String, session_token : String?) : String
      params = URI::Params.build do |form|
        form.add("Action", "DescribeInstances")
        form.add("Version", "2016-11-15")
        if filters = doc["filters"]?.try(&.as_a?)
          filter_number = 0
          filters.each do |filter|
            next unless expression = filter.as_s?
            name, _, values = expression.partition('=')
            filter_number += 1
            form.add("Filter.#{filter_number}.Name", name)
            values.split(',').each_with_index do |value, value_number|
              form.add("Filter.#{filter_number}.Value.#{value_number + 1}", value.strip)
            end
          end
        end
      end

      host = "ec2.#{region}.amazonaws.com"
      request = HTTP::Request.new("POST", "/", HTTP::Headers{
        "Host"         => host,
        "Content-Type" => "application/x-www-form-urlencoded",
      }, params.to_s)

      signer = Awscr::Signer::Signers::V4.new("ec2", region, access_key, secret_key, session_token)
      signer.sign(request)

      response = HTTP::Client.new(host, tls: true).exec(request)
      unless response.status.success?
        raise "aws_ec2 inventory: DescribeInstances in #{region} failed: HTTP #{response.status.code}: #{response.body[0, 500]}"
      end

      response.body
    end

    # Build hosts from a DescribeInstances XML response. Split out from
    # parse_aws_ec2 so specs can exercise the mapping without network.
    def self.build_aws_ec2_hosts(inventory : Inventory, xml : String, options : YAML::Any, region : String) : Nil
      root = XML.parse(xml).root
      return unless root

      hostnames = if raw = options["hostnames"]?
                    raw.as_a?.try(&.map(&.as_s)) || [raw.as_s]
                  else
                    ["ip-address", "private-ip-address", "instance-id"]
                  end

      each_instance(root) do |instance, instance_region|
        next if terminated?(instance)

        fields, tags = instance_fields(instance, instance_region)
        next unless hostname = resolve_hostname(fields, tags, hostnames)

        host = Host.new(hostname)
        host.vars["ansible_host"] = JSON::Any.new(hostname)
        tags.each do |tag_key, tag_value|
          # Both flat spellings real roles reach for, plus the tags dict.
          host.vars["tag.#{tag_key}"] = JSON::Any.new(tag_value)
          host.vars["tag:#{tag_key}"] = JSON::Any.new(tag_value)
        end
        host.vars["tags"] = JSON::Any.new(tags.map { |k, v| {k, JSON::Any.new(v)} }.to_h)
        fields.each do |key, value|
          host.vars[key] = JSON::Any.new(value)
        end

        inventory.add_host(host)
        inventory.get_or_create_group("all").add_host(host)
      end
    end

    private def self.terminated?(instance : XML::Node) : Bool
      state = child(instance, "instanceState").try { |state_node| child(state_node, "name").try(&.content) }
      state == "terminated" || state == "shutting-down"
    end

    private def self.each_instance(root : XML::Node, & : XML::Node, String -> Nil) : Nil
      reservations = child(root, "reservationSet") || return
      reservations.children.select { |node| node.name == "item" }.each do |reservation|
        instances = child(reservation, "instancesSet") || next
        instances.children.select { |node| node.name == "item" }.each do |instance|
          zone = child(instance, "placement").try { |placement| child(placement, "availabilityZone").try(&.content) }
          instance_region = zone ? zone.rchop : ""
          yield instance, instance_region
        end
      end
    end

    # The flat host-var subset real aws_ec2 sets, derived from one
    # <item> instance element: scalar fields plus the instance's tags.
    private def self.instance_fields(instance : XML::Node, region : String) : Tuple(Hash(String, String), Hash(String, String))
      fields = Hash(String, String).new

      scalars = {
        "instance_id"        => "instanceId",
        "instance_type"      => "instanceType",
        "public_ip_address"  => "ipAddress",
        "private_ip_address" => "privateIpAddress",
        "public_dns_name"    => "dnsName",
        "private_dns_name"   => "privateDnsName",
        "architecture"       => "architecture",
        "subnet_id"          => "subnetId",
        "vpc_id"             => "vpcId",
      }
      scalars.each do |var_name, xml_name|
        value = child(instance, xml_name).try(&.content)
        next if value.nil? || value.empty?
        fields[var_name] = value
      end

      state = child(instance, "instanceState").try { |state_node| child(state_node, "name").try(&.content) }
      fields["state"] = state if state

      fields["region"] = region unless region.empty?

      tags = Hash(String, String).new
      if tag_set = child(instance, "tagSet")
        tag_set.children.select { |node| node.name == "item" }.each do |item|
          key = child(item, "key").try(&.content)
          value = child(item, "value").try(&.content)
          next if key.nil? || key.empty?
          tags[key] = value || ""
        end
      end

      {fields, tags}
    end

    # Resolve the host name from the `hostnames` option list: the first
    # entry that produces a value wins. Types: dns-name, private-dns-name,
    # ip-address, private-ip-address, instance-id, tag:<Key> (or tag.<Key>).
    private def self.resolve_hostname(fields : Hash(String, String), tags : Hash(String, String), hostnames : Array(String)) : String?
      hostnames.each do |entry|
        value = case entry
                when "dns-name"           then fields["public_dns_name"]?
                when "private-dns-name"   then fields["private_dns_name"]?
                when "ip-address"         then fields["public_ip_address"]?
                when "private-ip-address" then fields["private_ip_address"]?
                when "instance-id"        then fields["instance_id"]?
                else
                  tag_key = entry.lchop("tag:").lchop("tag.")
                  tags[tag_key]?
                end
        next if value.nil? || (value.is_a?(String) && value.empty?)
        return value
      end
      nil
    end

    # The constructed-style option machinery shared by the `constructed`
    # plugin and aws_ec2: filters, keyed_groups, groups and compose,
    # applied to every host already in *inventory*.
    def self.apply_constructed_options(inventory : Inventory, doc : YAML::Any) : Inventory
      options = doc.as_h?
      return inventory unless options

      kept = constructed_filters(inventory, options["filters"]?)

      options["groups"]?.try do |groups|
        apply_constructed_groups(inventory, kept, groups)
      end

      options["keyed_groups"]?.try do |keyed_groups|
        leading = options["leading_separator"]?
        leading_value = leading.try(&.as_s?) || leading.try(&.as_bool?)
        apply_keyed_groups(inventory, kept, keyed_groups, leading_value != false)
      end

      options["compose"]?.try do |compose|
        apply_compose(kept, compose)
      end

      inventory
    end

    # `filters`: every entry ("key=value", bare "key" existence check,
    # "*" always-match, "!..." negation) must pass (AND). Non-matching
    # hosts stay in the inventory but get no keyed_groups/compose/groups
    # applied - matches real constructed, whose filters only gate its own
    # transformations.
    private def self.constructed_filters(inventory : Inventory, filters : YAML::Any?) : Array(Host)
      hosts = inventory.hosts.values
      return hosts unless filters

      entries = filters.as_a?.try(&.map(&.as_s)) || [filters.as_s]
      hosts.select do |host|
        entries.all? do |entry|
          entry = entry.strip
          negated = entry.starts_with?('!')
          entry = entry[1..].strip if negated

          matched = if entry == "*"
                      true
                    else
                      name, _, value = entry.partition('=')
                      if name.empty?
                        true
                      elsif value.empty?
                        !resolve_var_path(host.vars, name).nil?
                      else
                        resolve_var_path(host.vars, name).try(&.as_s?) == value
                      end
                    end
          negated ? !matched : matched
        end
      end
    end

    # `groups`: map of group name to a Jinja-like condition (string or
    # list of strings - any true adds the host). Evaluated with the same
    # ConditionalEvaluator task `when:` uses; a condition referencing an
    # undefined variable is false, not an error.
    private def self.apply_constructed_groups(inventory : Inventory, hosts : Array(Host), groups : YAML::Any) : Nil
      return unless group_hash = groups.as_h?
      group_hash.each do |group_name, conditions|
        group_name = group_name.to_s
        condition_list = conditions.as_a?.try(&.map(&.as_s)) || [conditions.as_s?].compact

        hosts.each do |host|
          matched = condition_list.any? do |condition|
            begin
              ConditionalEvaluator.evaluate(condition, host.vars)
            rescue
              false
            end
          end
          inventory.get_or_create_group(group_name).add_host(host) if matched
        end
      end
    end

    # `keyed_groups`: one group per distinct rendered key value, named
    # "<prefix><separator><value>" (dashes etc. sanitized to underscores).
    # A list value makes one group per element; a dict value makes one
    # group per key.
    private def self.apply_keyed_groups(inventory : Inventory, hosts : Array(Host), keyed_groups : YAML::Any, leading_separator : Bool) : Nil
      return unless list = keyed_groups.as_a?

      list.each do |entry|
        next unless config = entry.as_h?
        key_expr = config["key"]?.try(&.as_s?) || next
        prefix = config["prefix"]?.try(&.as_s?) || ""
        separator = config["separator"]?.try(&.as_s?) || "_"

        hosts.each do |host|
          values = keyed_group_values(host, key_expr)
          values.each do |value|
            name = "#{prefix}#{separator}#{value}"
            name = name.lchop(separator) if !leading_separator && prefix.empty?
            inventory.get_or_create_group(sanitize_group_name(name)).add_host(host)
          end
        end
      end
    end

    # The distinct group-name suffixes one host yields for a keyed_group
    # key: scalar -> one, list -> per element, dict -> per key.
    private def self.keyed_group_values(host : Host, key_expr : String) : Array(String)
      json = resolve_var_path(host.vars, key_expr)
      unless json
        rendered = begin
          VariableSubstitutor::ExpressionEvaluator.new(host.vars).evaluate(key_expr)
        rescue
          nil
        end
        return rendered ? [rendered] : [] of String
      end

      case raw = json.raw
      when Nil                     then [] of String
      when String                  then raw.empty? ? [] of String : [raw]
      when Bool, Int64, Float64    then [raw.to_s]
      when Array(JSON::Any)        then raw.flat_map { |item| keyed_group_values_json(item) }
      when Hash(String, JSON::Any) then raw.keys.map(&.to_s)
      else                              [raw.to_s]
      end
    end

    private def self.keyed_group_values_json(json : JSON::Any) : Array(String)
      case raw = json.raw
      when Nil                  then [] of String
      when String               then raw.empty? ? [] of String : [raw]
      when Bool, Int64, Float64 then [raw.to_s]
      when Array(JSON::Any)     then raw.flat_map { |item| keyed_group_values_json(item) }
      else                           [json.to_s]
      end
    end

    # `compose`: map of host var name to a Jinja-like expression (string,
    # or list - rendered element-wise). Undefined-variable failures skip
    # the var, matching real constructed's undefined-is-skip behavior.
    private def self.apply_compose(hosts : Array(Host), compose : YAML::Any) : Nil
      return unless compose_hash = compose.as_h?

      hosts.each do |host|
        compose_hash.each do |var_name, expression|
          values = if expression.as_a?
                     expression.as_a.compact_map do |item|
                       render_compose_value(host, item.as_s?)
                     end
                   else
                     [render_compose_value(host, expression.as_s?)].compact
                   end
          next if values.empty?

          rendered = values.size == 1 ? JSON::Any.new(values.first) : JSON::Any.new(values.map { |v| JSON::Any.new(v) })
          host.vars[var_name.to_s] = rendered

          case var_name.to_s
          when "ansible_user"
            host.user = values.first
          when "ansible_port"
            host.port = values.first.to_i? || host.port
          end
        end
      end
    end

    private def self.render_compose_value(host : Host, expression : String?) : String?
      return nil unless expression
      begin
        VariableSubstitutor::ExpressionEvaluator.new(host.vars).evaluate(expression)
      rescue
        resolve_var_path(host.vars, expression).try(&.as_s?) ||
          resolve_var_path(host.vars, expression).try(&.to_s)
      end
    end

    # Resolve a (possibly dotted) variable path against host vars: nested
    # dicts first ("tags.Environment"), falling back to the literal
    # flat key ("tag.Name" is a real flat var name in aws_ec2 output).
    private def self.resolve_var_path(vars : Hash(String, JSON::Any), path : String) : JSON::Any?
      segments = path.split('.')
      return nil if segments.empty?

      if segments.size == 1
        return vars[segments.first]?
      end

      current = vars[segments.first]?
      segments[1..].each do |segment|
        return nil unless current
        current = current.as_h?.try(&.[segment]?)
      end
      current
    end

    private def self.sanitize_group_name(name : String) : String
      name.gsub(/[^A-Za-z0-9_]/, "_")
    end

    private def self.child(node : XML::Node, name : String) : XML::Node?
      node.children.find { |candidate| candidate.name == name }
    end
  end
end
