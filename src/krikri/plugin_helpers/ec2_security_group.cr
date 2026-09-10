require "json"
require "../base_plugin"

module Krikri
  module PluginHelpers
    # Decision logic for amazon.aws.ec2_security_group - manage a
    # security group and its ingress/egress rules via the EC2 Query API
    # (DescribeSecurityGroups/CreateSecurityGroup/
    # AuthorizeSecurityGroup{Ingress,Egress}/RevokeSecurityGroup{Ingress,
    # Egress}/DeleteSecurityGroup/CreateTags), through the shared
    # PluginHelpers::Ec2Api signed-request helper.
    #
    # Like Ec2Key, the plan functions take the module params plus the
    # ALREADY-FETCHED DescribeSecurityGroups result and return the exact
    # mutating calls to make; the full #run wires it together and specs
    # drive it through the Ec2Api transport seam.
    #
    # Behavior mirrors the real module:
    # - rules/rules_egress are lists of {proto, from_port, to_port,
    #   cidr_ip, cidr_ipv6, group_id, group_name, prefix_list_id} dicts;
    #   a rule with no source at all defaults to 0.0.0.0/0.
    # - rules present on the group but not in the desired list are
    #   revoked when purge_rules (resp. purge_rules_egress) is true
    #   (the default) - including the default allow-all egress rule AWS
    #   creates with every new group, which real Ansible also revokes
    #   the first time rules_egress is managed.
    # - proto "all" normalizes to "-1" with no port range.
    module Ec2SecurityGroup
      record Rule,
        proto : String,
        from_port : String?,
        to_port : String?,
        cidr_ips : Array(String),
        cidr_ipv6s : Array(String),
        group_ids : Array(String),
        group_names : Array(String),
        prefix_list_ids : Array(String) do
        # Comparison key - the exact permission this rule describes,
        # source lists order-normalized. Two rules are "the same
        # permission" iff their canonicals match.
        def canonical : String
          sources = (cidr_ips + cidr_ipv6s + group_ids + group_names + prefix_list_ids).sort
          "#{proto}|#{from_port}|#{to_port}|#{sources.join(",")}"
        end
      end

      record Plan,
        steps : Array(Ec2Api::Step),
        changed : Bool,
        msg : String,
        group_id : String

      # -- param parsing ---------------------------------------------------

      # The rules/rules_egress params arrive as JSON-encoded lists of
      # dicts (the same string-hash the plugin binary receives).
      def self.parse_rules(raw : String?) : Array(Rule)
        raw_rules = raw
        return [] of Rule if raw_rules.nil? || raw_rules.empty?
        parsed = JSON.parse(raw_rules)
        return [] of Rule unless parsed.as_a?

        parsed.as_a.compact_map do |entry|
          next unless hash = entry.as_h?
          parse_rule_hash(hash)
        end
      rescue
        [] of Rule
      end

      private def self.parse_rule_hash(hash : Hash(String, JSON::Any)) : Rule
        proto = string_field(hash, "proto") || "tcp"
        proto = "-1" if proto == "all"
        from_port = string_field(hash, "from_port")
        to_port = string_field(hash, "to_port")
        if to_port.nil? && from_port
          to_port = from_port
        end

        cidr_ips = string_list_field(hash, "cidr_ip")
        cidr_ipv6s = string_list_field(hash, "cidr_ipv6")
        group_ids = string_list_field(hash, "group_id")
        group_names = string_list_field(hash, "group_name")
        prefix_list_ids = string_list_field(hash, "prefix_list_id")

        if cidr_ips.empty? && cidr_ipv6s.empty? && group_ids.empty? && group_names.empty? && prefix_list_ids.empty?
          cidr_ips = ["0.0.0.0/0"]
        end

        Rule.new(proto, from_port, to_port, cidr_ips, cidr_ipv6s, group_ids, group_names, prefix_list_ids)
      end

      private def self.string_field(hash : Hash(String, JSON::Any), key : String) : String?
        value = hash[key]?
        return nil if value.nil? || value == JSON::Any.new(nil)
        text = value.as_s? || value.to_s
        text.empty? ? nil : text
      end

      private def self.string_list_field(hash : Hash(String, JSON::Any), key : String) : Array(String)
        value = hash[key]?
        return [] of String if value.nil?
        if list = value.as_a?
          list.compact_map do |entry|
            text = entry.as_s? || entry.to_s
            text.empty? ? nil : text
          end
        else
          text = value.as_s? || value.to_s
          text.empty? ? [] of String : [text]
        end
      end

      # -- existing-rule parsing -------------------------------------------

      record SecurityGroup,
        group_id : String,
        group_name : String,
        description : String,
        vpc_id : String,
        ingress : Array(Rule),
        egress : Array(Rule),
        tags : Hash(String, String)

      # DescribeSecurityGroupsResponse -> list of groups.
      def self.parse_security_groups(root : XML::Node) : Array(SecurityGroup)
        info = Ec2Api.child(root, "securityGroupInfo") || return [] of SecurityGroup
        info.children.select { |node| node.name == "item" }.map do |item|
          SecurityGroup.new(
            group_id: Ec2Api.text(item, "groupId") || "",
            group_name: Ec2Api.text(item, "groupName") || "",
            description: Ec2Api.text(item, "groupDescription") || "",
            vpc_id: Ec2Api.text(item, "vpcId") || "",
            ingress: parse_permissions(item, "ipPermissionsSet"),
            egress: parse_permissions(item, "ipPermissionsEgressSet"),
            tags: Ec2Api.parse_tags(item),
          )
        end
      end

      private def self.parse_permissions(group_item : XML::Node, set_name : String) : Array(Rule)
        set = Ec2Api.child(group_item, set_name) || return [] of Rule
        set.children.select { |node| node.name == "item" }.map do |perm|
          cidr_ips = Ec2Api.items(perm, "ipRanges").compact_map { |range| Ec2Api.text(range, "cidrIp") }
          cidr_ipv6s = Ec2Api.items(perm, "ipv6Ranges").compact_map { |range| Ec2Api.text(range, "cidrIpv6") }
          group_ids = Ec2Api.items(perm, "groups").compact_map { |grp| Ec2Api.text(grp, "groupId") }
          group_names = Ec2Api.items(perm, "groups").compact_map { |grp| Ec2Api.text(grp, "groupName") }
          prefix_ids = Ec2Api.items(perm, "prefixListIds").compact_map { |pfx| Ec2Api.text(pfx, "prefixListId") }
          from_port = Ec2Api.text(perm, "fromPort")
          to_port = Ec2Api.text(perm, "toPort")
          Rule.new(
            proto: Ec2Api.text(perm, "ipProtocol") || "-1",
            from_port: from_port,
            to_port: to_port,
            cidr_ips: cidr_ips,
            cidr_ipv6s: cidr_ipv6s,
            group_ids: group_ids,
            group_names: group_names,
            prefix_list_ids: prefix_ids,
          )
        end
      end

      # Nested {filter-name => values} pairs describing the name (and,
      # when given, vpc) lookup the plugin performs before planning -
      # feed through Ec2Api.filter_params to flatten for the wire.
      def self.describe_filter(name : String, vpc_id : String?) : Array(Tuple(String, Array(String)))
        filters = [{"group-name", [name]}] of Tuple(String, Array(String))
        filters << {"vpc-id", [vpc_id]} if vpc_id && !vpc_id.empty?
        filters
      end

      # -- diffing ---------------------------------------------------------

      record RuleDiff, authorize : Array(Rule), revoke : Array(Rule)

      def self.diff_rules(desired : Array(Rule), existing : Array(Rule), purge : Bool) : RuleDiff
        existing_canonicals = existing.map(&.canonical).to_set
        desired_canonicals = desired.map(&.canonical).to_set

        authorize = desired.reject { |rule| existing_canonicals.includes?(rule.canonical) }
        revoke = purge ? existing.reject { |rule| desired_canonicals.includes?(rule.canonical) } : [] of Rule
        RuleDiff.new(authorize, revoke)
      end

      # -- wire params ------------------------------------------------------

      # IpPermissions.N.* pairs for one Authorize/Revoke call covering
      # several rules - N indexes the rules, M the (list) sources within
      # each. *prefix* is "IpPermissions" for both ingress and egress
      # (the Egress variant of the API call differs by Action name only).
      def self.permission_params(rules : Array(Rule)) : Array(Tuple(String, String))
        pairs = [] of Tuple(String, String)
        rules.each_with_index do |rule, index|
          n = index + 1
          pairs << {"IpPermissions.#{n}.IpProtocol", rule.proto}
          from_port = rule.from_port
          to_port = rule.to_port
          pairs << {"IpPermissions.#{n}.FromPort", from_port} if from_port
          pairs << {"IpPermissions.#{n}.ToPort", to_port} if to_port
          rule.cidr_ips.each_with_index do |cidr, idx|
            pairs << {"IpPermissions.#{n}.IpRanges.#{idx + 1}.CidrIp", cidr}
          end
          rule.cidr_ipv6s.each_with_index do |cidr, idx|
            pairs << {"IpPermissions.#{n}.Ipv6Ranges.#{idx + 1}.CidrIpv6", cidr}
          end
          rule.group_ids.each_with_index do |gid, idx|
            pairs << {"IpPermissions.#{n}.Groups.#{idx + 1}.GroupId", gid}
          end
          rule.group_names.each_with_index do |gname, idx|
            pairs << {"IpPermissions.#{n}.Groups.#{idx + 1}.GroupName", gname}
          end
          rule.prefix_list_ids.each_with_index do |pid, idx|
            pairs << {"IpPermissions.#{n}.PrefixListIds.#{idx + 1}.PrefixListId", pid}
          end
        end
        pairs
      end

      # -- planning ---------------------------------------------------------

      def self.plan_present(group_name : String, description : String?, vpc_id : String?,
                            ingress : Array(Rule)?, egress : Array(Rule)?,
                            purge_rules : Bool, purge_rules_egress : Bool,
                            tags : Hash(String, String), existing : Array(SecurityGroup)) : Plan
        current = existing.find { |grp| grp.group_name == group_name }

        unless current
          create_params = [
            {"GroupName", group_name},
            {"GroupDescription", description || "Created by krikri-playbook"},
          ]
          create_params << {"VpcId", vpc_id} if vpc_id && !vpc_id.empty?

          steps = [Ec2Api::Step.new("CreateSecurityGroup", create_params)]
          steps << Ec2Api::Step.new("AuthorizeSecurityGroupIngress", permission_params(ingress)) if ingress && !ingress.empty?
          steps << Ec2Api::Step.new("AuthorizeSecurityGroupEgress", permission_params(egress)) if egress && !egress.empty?
          return Plan.new(steps, true, "security group #{group_name} created", "")
        end

        steps = [] of Ec2Api::Step
        changed = false

        # nil rules/rules_egress means the param was not supplied - those
        # directions are left untouched, matching real Ansible (purge only
        # applies where a desired list was actually given).
        if ingress
          ingress_diff = diff_rules(ingress, current.ingress, purge_rules)
          unless ingress_diff.authorize.empty?
            steps << Ec2Api::Step.new("AuthorizeSecurityGroupIngress", permission_params(ingress_diff.authorize))
            changed = true
          end
          unless ingress_diff.revoke.empty?
            steps << Ec2Api::Step.new("RevokeSecurityGroupIngress", permission_params(ingress_diff.revoke))
            changed = true
          end
        end

        if egress
          egress_diff = diff_rules(egress, current.egress, purge_rules_egress)
          unless egress_diff.authorize.empty?
            steps << Ec2Api::Step.new("AuthorizeSecurityGroupEgress", permission_params(egress_diff.authorize))
            changed = true
          end
          unless egress_diff.revoke.empty?
            steps << Ec2Api::Step.new("RevokeSecurityGroupEgress", permission_params(egress_diff.revoke))
            changed = true
          end
        end

        missing_tags = tags.reject { |key, value| current.tags[key]? == value }
        unless missing_tags.empty?
          steps << Ec2Api::Step.new("CreateTags", [{"ResourceId.1", current.group_id}] + Ec2Api.tag_params(missing_tags))
          changed = true
        end

        msg = changed ? "security group #{group_name} updated" : "security group #{group_name} already up to date"
        Plan.new(steps, changed, msg, current.group_id)
      end

      def self.plan_absent(existing : Array(SecurityGroup), group_name : String) : Plan
        current = existing.find { |grp| grp.group_name == group_name }
        return Plan.new([] of Ec2Api::Step, false, "security group #{group_name} already absent", "") unless current

        Plan.new(
          [Ec2Api::Step.new("DeleteSecurityGroup", [{"GroupId", current.group_id}])],
          true,
          "security group #{group_name} deleted",
          current.group_id,
        )
      end

      # -- full module run ---------------------------------------------------

      def self.run(params : Hash(String, String)) : Krikri::PluginResult
        name = params["name"]?
        if name.nil? || name.empty?
          return Krikri::PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
        end

        state = params["state"]? || "present"
        unless ["present", "absent"].includes?(state)
          return Krikri::PluginResult.new(changed: false, failed: true, msg: "state must be present or absent, got #{state}")
        end

        vpc_id = params["vpc_id"]?
        region = Ec2Api.resolve_region(params["region"]?)
        credentials = Ec2Api.resolve_credentials

        existing = describe_security_groups(region, credentials, name, vpc_id)

        if state == "absent"
          plan = plan_absent(existing, name)
        else
          # Only the directions whose param was actually supplied are
          # managed; absent rules/rules_egress leave existing rules alone.
          ingress = params.has_key?("rules") ? parse_rules(params["rules"]?) : nil
          egress = params.has_key?("rules_egress") ? parse_rules(params["rules_egress"]?) : nil
          plan = plan_present(
            name, params["description"]?, vpc_id,
            ingress, egress,
            bool_param(params["purge_rules"]?, true), bool_param(params["purge_rules_egress"]?, true),
            parse_tags(params), existing,
          )
        end

        check_mode = bool_param(params["check_mode"]?)
        return Krikri::PluginResult.new(changed: plan.changed, failed: false, msg: "#{plan.msg} (check mode)") if check_mode

        group_id = plan.group_id
        plan.steps.each do |step|
          root = Ec2Api.call(region, step.action, Ec2Api.to_form_params(step.params), credentials)
          if step.action == "CreateSecurityGroup"
            group_id = Ec2Api.text(root, "groupId") || group_id
          end
        end

        result = Krikri::PluginResult.new(changed: plan.changed, failed: false, msg: plan.msg)
        result.extra["group_id"] = JSON.parse(group_id.to_json)
        result.extra["name"] = JSON.parse(name.to_json)
        result
      rescue ex : Ec2Api::Error
        Krikri::PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
      end

      private def self.bool_param(raw : String?, default : Bool = false) : Bool
        return default if raw.nil? || raw.empty?
        raw == "true" || raw == "True" || raw == "yes"
      end

      private def self.describe_security_groups(region : String, credentials : Ec2Api::Credentials, name : String, vpc_id : String?) : Array(SecurityGroup)
        params = Ec2Api.to_form_params(Ec2Api.filter_params(describe_filter(name, vpc_id)))
        root = Ec2Api.call(region, "DescribeSecurityGroups", params, credentials)
        parse_security_groups(root)
      end

      private def self.parse_tags(params : Hash(String, String)) : Hash(String, String)
        raw = params["tags"]?
        return {} of String => String unless raw
        parsed = JSON.parse(raw)
        return {} of String => String unless parsed.as_h?
        parsed.as_h.each_with_object(Hash(String, String).new) do |(key, value), tags|
          next unless string = value.as_s?
          tags[key] = string
        end
      rescue
        {} of String => String
      end
    end
  end
end
