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
    # - a rule may instead carry `ports`, a list of single ports and/or
    #   "N-M" range strings (real module docs, amazon.aws >= 2.4); each
    #   element becomes its own rule (from=to=port, or from=N to=M),
    #   expanded against the rule's source list like the real module's
    #   expand_rule.
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

        parsed.as_a.flat_map do |entry|
          hash = entry.as_h?
          hash ? parse_rule_hash(hash) : [] of Rule
        end
      rescue
        [] of Rule
      end

      # Returns one Rule per (ports x source) combination, mirroring the
      # real module's expand_rule: from_port/to_port win over ports, and
      # each `ports` element (a single port or an "N-M" range string)
      # becomes its own rule sharing the rule's source list.
      private def self.parse_rule_hash(hash : Hash(String, JSON::Any)) : Array(Rule)
        proto = string_field(hash, "proto") || "tcp"
        proto = "-1" if proto == "all"
        from_port = string_field(hash, "from_port")
        to_port = string_field(hash, "to_port")
        if to_port.nil? && from_port
          to_port = from_port
        end

        port_pairs = if from_port || to_port
                       [{from_port, to_port}]
                     else
                       string_list_field(hash, "ports").map { |spec| parse_ports_entry(spec) }
                     end

        cidr_ips = string_list_field(hash, "cidr_ip")
        cidr_ipv6s = string_list_field(hash, "cidr_ipv6")
        group_ids = string_list_field(hash, "group_id")
        group_names = string_list_field(hash, "group_name")
        prefix_list_ids = string_list_field(hash, "prefix_list_id")

        if cidr_ips.empty? && cidr_ipv6s.empty? && group_ids.empty? && group_names.empty? && prefix_list_ids.empty?
          cidr_ips = ["0.0.0.0/0"]
        end

        port_pairs.map do |(pair_from, pair_to)|
          Rule.new(proto, pair_from, pair_to, cidr_ips, cidr_ipv6s, group_ids, group_names, prefix_list_ids)
        end
      end

      # "22" -> (22, 22); "443-8443" -> (443, 8443), bounds sorted like
      # the real module's expand_ports_list (so "8443-443" still yields
      # 443 first).
      private def self.parse_ports_entry(spec : String) : Tuple(String?, String?)
        return {spec.strip, spec.strip} unless dash = spec.index('-')
        low = spec[0...dash].strip
        high = spec[(dash + 1)..].strip
        if (low_num = low.to_i?) && (high_num = high.to_i?) && low_num > high_num
          {high, low}
        else
          {low, high}
        end
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
        owner_id : String,
        arn : String,
        ingress : Array(Rule),
        egress : Array(Rule),
        tags : Hash(String, String)

      # DescribeSecurityGroupsResponse -> list of groups.
      def self.parse_security_groups(root : KXML::Element) : Array(SecurityGroup)
        info = Ec2Api.child(root, "securityGroupInfo") || return [] of SecurityGroup
        info.elements.select { |node| node.local_name == "item" }.map do |item|
          SecurityGroup.new(
            group_id: Ec2Api.text(item, "groupId") || "",
            group_name: Ec2Api.text(item, "groupName") || "",
            description: Ec2Api.text(item, "groupDescription") || "",
            vpc_id: Ec2Api.text(item, "vpcId") || "",
            owner_id: Ec2Api.text(item, "ownerId") || "",
            arn: Ec2Api.text(item, "securityGroupArn") || "",
            ingress: parse_permissions(item, "ipPermissions", "ipPermissionsSet"),
            egress: parse_permissions(item, "ipPermissionsEgress", "ipPermissionsEgressSet"),
            tags: Ec2Api.parse_tags(item),
          )
        end
      end

      # The real wire (verified live, 2026-09-13) names the permission sets
      # ipPermissions/ipPermissionsEgress; the *Set variants are accepted
      # for safety, since they appear in older API docs.
      private def self.parse_permissions(group_item : KXML::Element, *set_names : String) : Array(Rule)
        set_names.each do |set_name|
          set = Ec2Api.child(group_item, set_name) || next
          perms = set.elements.select { |node| node.local_name == "item" }
          next if perms.empty?
          return perms.map { |perm| parse_permission(perm) }
        end
        [] of Rule
      end

      private def self.parse_permission(perm : KXML::Element) : Rule
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
          # Real module's create path revokes the group's pre-existing
          # rules before authorizing the desired ones, and handles
          # ingress before egress (remove_old_permissions then
          # add_new_permissions).
          if egress
            # A freshly created VPC group already carries AWS's default
            # allow-all egress rule; with purge_rules_egress (the default)
            # real Ansible revokes it whenever the desired list is
            # supplied without it - including an explicitly empty one.
            default_egress = Rule.new("-1", nil, nil, ["0.0.0.0/0"], [] of String, [] of String, [] of String, [] of String)
            unless egress.any?(&.canonical.==(default_egress.canonical))
              steps << Ec2Api::Step.new("RevokeSecurityGroupEgress", permission_params([default_egress]))
            end
          end
          steps << Ec2Api::Step.new("AuthorizeSecurityGroupIngress", permission_params(ingress)) if ingress && !ingress.empty?
          steps << Ec2Api::Step.new("AuthorizeSecurityGroupEgress", permission_params(egress)) if egress && !egress.empty?
          # Tags are applied on the create path too (real Ansible does not
          # drop them); ResourceId is injected by #run - the group id only
          # exists after CreateSecurityGroup returns.
          steps << Ec2Api::Step.new("CreateTags", Ec2Api.tag_params(tags)) unless tags.empty?
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

      # -- result shaping ----------------------------------------------------
      # Real Ansible's ec2_security_group success result (verified live,
      # 2026-09-13) is the described group's boto3-shaped output:
      # description, group_id, group_name, ip_permissions,
      # ip_permissions_egress, owner_id, security_group_arn, tags,
      # vpc_id - no msg, no name. state: absent returns just
      # {changed, group_id: null} (the group is gone; nothing to describe),
      # and so does check mode against a group that doesn't exist yet.

      def self.group_result_fields(sg : SecurityGroup) : Hash(String, JSON::Any)
        JSON.parse(JSON.build do |json|
          json.object do
            json.field("description", sg.description)
            json.field("group_id", sg.group_id)
            json.field("group_name", sg.group_name)
            json.field("ip_permissions") { json_rules(json, sg.ingress) }
            json.field("ip_permissions_egress") { json_rules(json, sg.egress) }
            json.field("owner_id", sg.owner_id)
            json.field("security_group_arn", sg.arn)
            json.field("tags") do
              json.object do
                sg.tags.each { |key, value| json.field(key, value) }
              end
            end
            json.field("vpc_id", sg.vpc_id)
          end
        end).as_h
      end

      private def self.json_rules(json : JSON::Builder, rules : Array(Rule)) : Nil
        json.array do
          rules.each { |rule| json_rule(json, rule) }
        end
      end

      private def self.json_rule(json : JSON::Builder, rule : Rule) : Nil
        json.object do
          json.field("ip_protocol", rule.proto)
          json_port_field(json, "from_port", rule.from_port)
          json_port_field(json, "to_port", rule.to_port)
          json.field("ip_ranges") do
            json.array do
              rule.cidr_ips.each do |cidr|
                json.object do
                  json.field("cidr_ip", cidr)
                end
              end
            end
          end
          json.field("ipv6_ranges") do
            json.array do
              rule.cidr_ipv6s.each do |cidr|
                json.object do
                  json.field("cidr_ipv6", cidr)
                end
              end
            end
          end
          json.field("prefix_list_ids") do
            json.array do
              rule.prefix_list_ids.each do |pid|
                json.object do
                  json.field("prefix_list_id", pid)
                end
              end
            end
          end
          json.field("user_id_group_pairs") do
            json.array do
              rule.group_ids.each_with_index do |gid, index|
                gname = rule.group_names[index]?
                json.object do
                  json.field("group_id", gid)
                  json.field("group_name", gname) if gname && !gname.empty?
                end
              end
            end
          end
        end
      end

      # boto3 renders ports as native ints on the wire; keep strings only
      # when the value isn't numeric.
      private def self.json_port_field(json : JSON::Builder, name : String, port : String?) : Nil
        value = port || return
        if num = value.to_i64?
          json.field(name, num)
        else
          json.field(name, value)
        end
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

        check_mode = bool_param(params["_ansible_check_mode"]?)

        # state: absent never carries group fields - the group is gone (or
        # was never there), so there's nothing to describe; real Ansible
        # returns exactly {changed, group_id: null}. The delete step itself
        # still runs (unless check mode).
        if state == "absent"
          unless check_mode
            plan.steps.each do |step|
              Ec2Api.call(region, step.action, Ec2Api.to_form_params(step.params), credentials)
            end
          end
          result = Krikri::PluginResult.new(changed: plan.changed, failed: false)
          result.extra["group_id"] = JSON::Any.new(nil)
          return result
        end

        # Check mode against a group that doesn't exist yet: nothing to
        # describe either - real Ansible returns {changed: true, group_id:
        # null} there.
        if check_mode && plan.group_id.empty?
          result = Krikri::PluginResult.new(changed: plan.changed, failed: false)
          result.extra["group_id"] = JSON::Any.new(nil)
          return result
        end

        group_id = plan.group_id
        unless check_mode
          plan.steps.each do |step|
            step_params = step.params
            # Authorize/Revoke target the group explicitly by GroupId - the
            # EC2 API rejects the call without it (MissingParameter), and on
            # the create path the id only exists after CreateSecurityGroup
            # returns, so the plan can't carry it and #run injects it here.
            if step.action.starts_with?("AuthorizeSecurityGroup") || step.action.starts_with?("RevokeSecurityGroup")
              step_params = [{"GroupId", group_id}] + step_params
            end
            if step.action == "CreateTags" && step_params.none? { |(key, _)| key == "ResourceId.1" }
              step_params = [{"ResourceId.1", group_id}] + step_params
            end
            root = Ec2Api.call(region, step.action, Ec2Api.to_form_params(step_params), credentials)
            if step.action == "CreateSecurityGroup"
              group_id = Ec2Api.text(root, "groupId") || group_id
            end
          end
        end

        # Real Ansible ends every present-path result with the group's
        # current describe output - including in check mode against an
        # existing group (describe is read-only, so it runs there too).
        result = Krikri::PluginResult.new(changed: plan.changed, failed: false)
        describe_root = Ec2Api.call(region, "DescribeSecurityGroups",
          Ec2Api.to_form_params(Ec2Api.filter_params([{"group-id", [group_id]}])), credentials)
        group = parse_security_groups(describe_root).find { |grp| grp.group_id == group_id }
        if group
          group_result_fields(group).each do |key, value|
            result.extra[key] = value
          end
        else
          result.extra["group_id"] = group_id.empty? ? JSON::Any.new(nil) : JSON::Any.new(group_id)
        end
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
