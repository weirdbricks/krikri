require "json"
require "base64"
require "../base_plugin"
require "./ec2_api"
require "./ec2_info"

module Krikri
  module PluginHelpers
    # Decision logic for amazon.aws.ec2_instance - the instance lifecycle
    # module of the amazon.aws EC2 cluster (create, start, stop, restart,
    # terminate), through the shared PluginHelpers::Ec2Api signed-request
    # helper (RunInstances/StartInstances/StopInstances/
    # TerminateInstances/DescribeInstances/CreateTags/DeleteTags).
    #
    # Like Ec2Key/Ec2SecurityGroup, the plan functions take the module
    # params plus the ALREADY-FETCHED DescribeInstances result and return
    # the exact mutating calls to make; the full #run wires it together
    # and specs drive it through the Ec2Api transport seam.
    #
    # Behavior mirrors the real module's surface (params confirmed against
    # `ansible-doc amazon.aws.ec2_instance`):
    # - Targeting: `name` (the Name tag) or `instance_ids`, optionally
    #   narrowed by `filters`. The idempotency lookup always adds a
    #   non-terminated instance-state-name filter (pending/running/
    #   stopping/stopped) - a match in any of those states counts as
    #   existing for every state, and terminated instances never come
    #   back from DescribeInstances anyway.
    # - state=present: launch (RunInstances) when no match; otherwise a
    #   no-op except for tag drift (missing tags applied via CreateTags,
    #   extra tags deleted via DeleteTags when purge_tags is set - the
    #   real module's default - with aws:-reserved keys left alone).
    #   Attribute drift (instance_type, user_data, ...) is deliberately
    #   not diffed: present "ensures instances exist, but does not
    #   guarantee any state".
    # - state=running/started: launch when absent, StartInstances on
    #   stopped matches, no-op when already running.
    # - state=stopped: StopInstances on running matches; fails when no
    #   match exists (the real module cannot stop what is not there).
    # - state=restarted/rebooted: Stop then Start.
    # - state=terminated/absent: TerminateInstances, no-op when no match.
    # - count: always launches that many new instances (never reconciles).
    #   exact_count: reconciles the match set to N - launching the
    #   difference, or terminating the surplus oldest-first (least
    #   recently created, per the real module's documented Launch Time
    #   ordering).
    # - Tags: the `name` param is the Name tag; user `tags` are applied
    #   after RunInstances via a separate CreateTags call (RunInstances
    #   itself takes no tag params on the wire).
    # - wait (default true) polls DescribeInstances after any mutating
    #   call until every affected instance reaches the target state
    #   (running/stopped/terminated; a terminated instance that has left
    #   DescribeInstances entirely counts as terminated), up to
    #   wait_timeout (default 600s, the real module's default).
    #
    # Result shape matches real Ansible: `instances` is the list of
    # DescribeInstances items shaped by Ec2Info.jsonify (camel_to_snake'd
    # boto3 keys, `state` as the code/name dict, `tags` as the key-value
    # dict).
    module Ec2Instance
      VALID_STATES = ["present", "running", "started", "stopped", "restarted", "rebooted", "terminated", "absent"]

      # The states a "matching" instance may be in for the idempotency
      # lookup - everything except terminated/terminating.
      NON_TERMINATED_STATES = ["pending", "running", "stopping", "stopped"]

      record Instance,
        instance_id : String,
        state_name : String,
        launch_time : String,
        json : JSON::Any

      record Plan,
        steps : Array(Ec2Api::Step),
        changed : Bool,
        msg : String,
        # State to poll DescribeInstances for after the steps run (nil =
        # nothing to wait for).
        target_state : String?,
        # Existing instances the plan mutates (created ones are collected
        # from the RunInstances response at execution time).
        instance_ids : Array(String)

      # Test knob: seconds between DescribeInstances polls while waiting.
      # Defaults to 5; the specs set it to 0 so multi-poll loops run
      # instantly against the canned-XML transport seam (same role the
      # Ec2Api.transport seam itself plays).
      @@poll_interval : Float64 = 5.0

      def self.poll_interval=(value : Float64) : Nil
        @@poll_interval = value
      end

      def self.poll_interval : Float64
        @@poll_interval
      end

      # -- Describe-result parsing ------------------------------------------

      # DescribeInstancesResponse -> flat instance list across
      # reservationSet/item/instancesSet/item.
      def self.parse_instances(root : XML::Node) : Array(Instance)
        Ec2Api.items(root, "reservationSet").flat_map do |reservation|
          Ec2Api.items(reservation, "instancesSet").map do |item|
            state_name = Ec2Api.child(item, "instanceState").try do |state|
              Ec2Api.text(state, "name") || ""
            end || ""
            Instance.new(
              instance_id: Ec2Api.text(item, "instanceId") || "",
              state_name: state_name,
              launch_time: Ec2Api.text(item, "launchTime") || "",
              json: Ec2Info.jsonify(item),
            )
          end
        end
      end

      # -- Describe wire params ----------------------------------------------

      # InstanceId.N params plus the Filter.N.Name/Value.M pairs for the
      # lookup: the caller's extra filters, the tag:Name filter when
      # targeting by name (direct-ID targeting is exact already), and -
      # for the idempotency lookup only - the non-terminated state filter.
      def self.lookup_params(name : String?, instance_ids : Array(String), extra_filters : Array(Tuple(String, Array(String))), state_filter : Bool) : Array(Tuple(String, String))
        wire = [] of Tuple(String, String)
        instance_ids.each_with_index do |id, index|
          wire << {"InstanceId.#{index + 1}", id}
        end
        filters = extra_filters.dup
        filters << {"tag:Name", [name]} if name && instance_ids.empty?
        filters << {"instance-state-name", NON_TERMINATED_STATES} if state_filter
        wire + Ec2Api.filter_params(filters)
      end

      private def self.id_params(instance_ids : Array(String)) : Array(Tuple(String, String))
        instance_ids.each_with_index.map { |id, index| {"InstanceId.#{index + 1}", id} }.to_a
      end

      # -- tags ---------------------------------------------------------------

      # The full desired tag set: Name from the `name` param, overlaid by
      # the user `tags` dict (which may deliberately override Name).
      def self.desired_tags(name : String?, params : Hash(String, String)) : Hash(String, String)
        tags = Hash(String, String).new
        tags["Name"] = name if name
        parse_tags(params).each { |key, value| tags[key] = value }
        tags
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

      # Tag drift between the desired set and one instance's current tags:
      # CreateTags for the missing/changed, DeleteTags for the surplus
      # (only when purge_tags is set; aws:-reserved keys are never
      # deletable).
      def self.tag_diff_steps(desired : Hash(String, String), current : Hash(String, String), instance_id : String, purge : Bool) : Array(Ec2Api::Step)
        steps = [] of Ec2Api::Step
        missing = desired.reject { |key, value| current[key]? == value }
        unless missing.empty?
          steps << Ec2Api::Step.new("CreateTags", [{"ResourceId.1", instance_id}] + Ec2Api.tag_params(missing))
        end
        if purge
          extra = current.reject { |key, _| desired.has_key?(key) || key.starts_with?("aws:") }.keys
          unless extra.empty?
            pairs = [{"ResourceId.1", instance_id}]
            extra.each_with_index { |key, index| pairs << {"Tag.#{index + 1}.Key", key} }
            steps << Ec2Api::Step.new("DeleteTags", pairs)
          end
        end
        steps
      end

      private def self.instance_tags(inst : Instance) : Hash(String, String)
        tags = Hash(String, String).new
        if (hash = inst.json.as_h?) && (tag_hash = hash["tags"]?.try(&.as_h?))
          tag_hash.each do |key, value|
            tags[key] = value.as_s? || value.to_s
          end
        end
        tags
      end

      # -- launch params --------------------------------------------------------

      # RunInstances wire params. UserData is Base64-encoded (the EC2
      # Query API expects the encoded blob; boto3 does this conversion for
      # the real module).
      def self.run_instances_params(params : Hash(String, String), count : Int32) : Array(Tuple(String, String))
        wire = [
          {"MinCount", "1"},
          {"MaxCount", count.to_s},
        ] of Tuple(String, String)
        image_id = params["image_id"]?
        instance_type = params["instance_type"]?
        key_name = params["key_name"]?
        subnet_id = params["vpc_subnet_id"]?
        user_data = params["user_data"]?

        wire << {"ImageId", image_id} if image_id && !image_id.empty?
        wire << {"InstanceType", instance_type} if instance_type && !instance_type.empty?
        wire << {"KeyName", key_name} if key_name && !key_name.empty?
        wire << {"SubnetId", subnet_id} if subnet_id && !subnet_id.empty?
        security_groups(params).each_with_index do |group, index|
          wire << {"SecurityGroupId.#{index + 1}", group}
        end
        wire << {"UserData", Base64.strict_encode(user_data)} if user_data && !user_data.empty?
        wire
      end

      # security_group (single) + security_groups (list) collapse into one
      # SecurityGroupId.N list - the real module treats them as mutually
      # exclusive spellings of the same thing.
      def self.security_groups(params : Hash(String, String)) : Array(String)
        groups = Ec2Info.string_list(params["security_groups"]?)
        single = params["security_group"]?
        groups.unshift(single) if single && !single.empty?
        groups
      end

      private def self.plan_launch(params : Hash(String, String), count : Int32, wait : Bool) : Plan
        image_id = params["image_id"]?
        if image_id.nil? || image_id.empty?
          raise Ec2Api::Error.new("image_id is required when creating a new instance")
        end
        instance_type = params["instance_type"]?
        if instance_type.nil? || instance_type.empty?
          raise Ec2Api::Error.new("instance_type is required when creating a new instance")
        end

        Plan.new(
          [Ec2Api::Step.new("RunInstances", run_instances_params(params, count))],
          true,
          "#{count} instance(s) launched",
          wait ? "running" : nil,
          [] of String,
        )
      end

      # -- plans ---------------------------------------------------------------

      def self.plan_present(name : String?, params : Hash(String, String), existing : Array(Instance), wait : Bool) : Plan
        if existing.empty?
          return plan_launch(params, 1, wait)
        end

        purge = bool_param(params["purge_tags"]?, true)
        desired = desired_tags(name, params)
        steps = existing.flat_map do |inst|
          tag_diff_steps(desired, instance_tags(inst), inst.instance_id, purge)
        end
        changed = !steps.empty?
        msg = changed ? "tag(s) updated on #{existing.size} instance(s)" : "instance(s) already present"
        Plan.new(steps, changed, msg, nil, [] of String)
      end

      def self.plan_running(name : String?, params : Hash(String, String), existing : Array(Instance), wait : Bool) : Plan
        if existing.empty?
          return plan_launch(params, 1, wait)
        end

        stopped = existing.select { |inst| inst.state_name == "stopped" }
        if stopped.empty?
          return Plan.new([] of Ec2Api::Step, false, "instance(s) already running", nil, [] of String)
        end
        Plan.new(
          [Ec2Api::Step.new("StartInstances", id_params(stopped.map(&.instance_id)))],
          true,
          "started #{stopped.size} instance(s)",
          wait ? "running" : nil,
          stopped.map(&.instance_id),
        )
      end

      def self.plan_stopped(existing : Array(Instance), wait : Bool) : Plan
        if existing.empty?
          raise Ec2Api::Error.new("state=stopped but no matching instances found")
        end

        running = existing.select { |inst| inst.state_name == "running" }
        if running.empty?
          return Plan.new([] of Ec2Api::Step, false, "instance(s) already stopped", nil, [] of String)
        end
        Plan.new(
          [Ec2Api::Step.new("StopInstances", id_params(running.map(&.instance_id)))],
          true,
          "stopped #{running.size} instance(s)",
          wait ? "stopped" : nil,
          running.map(&.instance_id),
        )
      end

      def self.plan_restarted(existing : Array(Instance), wait : Bool) : Plan
        if existing.empty?
          raise Ec2Api::Error.new("state=restarted but no matching instances found")
        end

        running = existing.select { |inst| inst.state_name == "running" }
        stopped = existing.select { |inst| inst.state_name == "stopped" }
        steps = [] of Ec2Api::Step
        steps << Ec2Api::Step.new("StopInstances", id_params(running.map(&.instance_id))) unless running.empty?
        steps << Ec2Api::Step.new("StartInstances", id_params(stopped.map(&.instance_id))) unless stopped.empty?

        if steps.empty?
          return Plan.new([] of Ec2Api::Step, false, "instance(s) already restarted", nil, [] of String)
        end
        Plan.new(
          steps,
          true,
          "restarted #{running.size + stopped.size} instance(s)",
          wait ? "running" : nil,
          (running + stopped).map(&.instance_id),
        )
      end

      def self.plan_terminate(existing : Array(Instance), wait : Bool) : Plan
        if existing.empty?
          return Plan.new([] of Ec2Api::Step, false, "no matching instances found", nil, [] of String)
        end
        Plan.new(
          [Ec2Api::Step.new("TerminateInstances", id_params(existing.map(&.instance_id)))],
          true,
          "terminated #{existing.size} instance(s)",
          wait ? "terminated" : nil,
          existing.map(&.instance_id),
        )
      end

      # -- waiting -------------------------------------------------------------

      # Poll DescribeInstances until every requested instance reaches the
      # target state. A terminated instance that has dropped out of
      # DescribeInstances entirely counts as terminated (EC2 removes it
      # from the response once the termination fully settles).
      def self.wait_for(region : String, credentials : Ec2Api::Credentials, instance_ids : Array(String), target_state : String, timeout : Int32) : Array(Instance)
        deadline = Time.monotonic + Time::Span.new(seconds: timeout)
        loop do
          found = describe_instances(region, credentials, lookup_params(nil, instance_ids, [] of Tuple(String, Array(String)), state_filter: false))
          reached = instance_ids.all? do |id|
            inst = found.find { |candidate| candidate.instance_id == id }
            if target_state == "terminated"
              inst.nil? || inst.state_name == "terminated"
            else
              inst && inst.state_name == target_state
            end
          end
          return found if reached

          if Time.monotonic >= deadline
            raise Ec2Api::Error.new("timed out waiting for instance(s) #{instance_ids.join(", ")} to reach state #{target_state}")
          end
          sleep @@poll_interval
        end
      end

      # -- full module run -------------------------------------------------------

      def self.run(params : Hash(String, String)) : Krikri::PluginResult
        state = params["state"]? || "present"
        unless VALID_STATES.includes?(state)
          return Krikri::PluginResult.new(changed: false, failed: true, msg: "state must be one of #{VALID_STATES.join(", ")}, got #{state}")
        end

        name = params["name"]?.try { |value| value.empty? ? nil : value }
        instance_ids = Ec2Info.string_list(params["instance_ids"]?)
        filters = Ec2Info.parse_filters(params["filters"]?)
        count_raw = params["count"]?
        exact_count_raw = params["exact_count"]?

        if count_raw && exact_count_raw
          return Krikri::PluginResult.new(changed: false, failed: true, msg: "count and exact_count are mutually exclusive")
        end
        if name.nil? && instance_ids.empty? && filters.empty? && count_raw.nil? && exact_count_raw.nil?
          return Krikri::PluginResult.new(changed: false, failed: true, msg: "one of name, instance_ids, filters, count, or exact_count is required")
        end

        wait = bool_param(params["wait"]?, true)
        wait_timeout = params["wait_timeout"]?.try(&.to_i?) || 600
        region = Ec2Api.resolve_region(params["region"]?)
        credentials = Ec2Api.resolve_credentials

        existing = describe_instances(
          region, credentials,
          lookup_params(name, instance_ids, filters, state_filter: true),
        )

        plan = if count_raw
                 count = count_raw.to_i?
                 if count.nil? || count <= 0
                   raise Ec2Api::Error.new("count must be a positive integer, got #{count_raw}")
                 end
                 plan_launch(params, count, wait)
               elsif exact_count_raw
                 exact_count = exact_count_raw.to_i?
                 if exact_count.nil? || exact_count < 0
                   raise Ec2Api::Error.new("exact_count must be a non-negative integer, got #{exact_count_raw}")
                 end
                 plan_exact_count(params, exact_count, existing, wait)
               else
                 case state
                 when "terminated", "absent" then plan_terminate(existing, wait)
                 when "present"              then plan_present(name, params, existing, wait)
                 when "running", "started"   then plan_running(name, params, existing, wait)
                 when "stopped"              then plan_stopped(existing, wait)
                 when "restarted", "rebooted" then plan_restarted(existing, wait)
                 else
                   raise Ec2Api::Error.new("unhandled state #{state}")
                 end
               end

        check_mode = bool_param(params["check_mode"]?)
        return Krikri::PluginResult.new(changed: plan.changed, failed: false, msg: "#{plan.msg} (check mode)") if check_mode

        created_ids = [] of String
        plan.steps.each do |step|
          root = Ec2Api.call(region, step.action, Ec2Api.to_form_params(step.params), credentials)
          if step.action == "RunInstances"
            Ec2Api.items(root, "instancesSet").each do |item|
              id = Ec2Api.text(item, "instanceId")
              created_ids << id if id && !id.empty?
            end
          end
        end

        # RunInstances takes no tag params on the wire, so the Name tag +
        # user tags go on as a separate CreateTags call afterwards (same
        # post-plan tag application Ec2Key does).
        tags = desired_tags(name, params)
        if !created_ids.empty? && !tags.empty?
          wire = created_ids.each_with_index.map { |id, index| {"ResourceId.#{index + 1}", id} }.to_a + Ec2Api.tag_params(tags)
          Ec2Api.call(region, "CreateTags", Ec2Api.to_form_params(wire), credentials)
        end

        affected = plan.instance_ids + created_ids
        result_instances : Array(JSON::Any) = if affected.empty?
          existing.map(&.json)
        elsif wait && (target_state = plan.target_state)
          wait_for(region, credentials, affected, target_state, wait_timeout).map(&.json)
        else
          describe_instances(region, credentials, lookup_params(nil, affected, [] of Tuple(String, Array(String)), state_filter: false)).map(&.json)
        end

        result = Krikri::PluginResult.new(changed: plan.changed, failed: false, msg: plan.msg)
        result.extra["instances"] = JSON::Any.new(result_instances)
        result
      rescue ex : Ec2Api::Error
        Krikri::PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
      end

      private def self.plan_exact_count(params : Hash(String, String), exact_count : Int32, existing : Array(Instance), wait : Bool) : Plan
        if existing.size < exact_count
          plan = plan_launch(params, exact_count - existing.size, wait)
          plan = Plan.new(plan.steps, plan.changed, "#{plan.msg} (exact_count #{exact_count})", plan.target_state, plan.instance_ids)
          return plan
        end

        if existing.size > exact_count
          # Least recently created first, per the real module's documented
          # Launch Time ordering.
          surplus = existing.sort_by(&.launch_time).first(existing.size - exact_count)
          plan = plan_terminate(surplus, wait)
          return Plan.new(plan.steps, plan.changed, "#{plan.msg} (exact_count #{exact_count})", plan.target_state, plan.instance_ids)
        end

        Plan.new([] of Ec2Api::Step, false, "#{exact_count} instance(s) already match", nil, [] of String)
      end

      private def self.describe_instances(region : String, credentials : Ec2Api::Credentials, wire : Array(Tuple(String, String))) : Array(Instance)
        root = Ec2Api.call(region, "DescribeInstances", Ec2Api.to_form_params(wire), credentials)
        parse_instances(root)
      end

      private def self.bool_param(raw : String?, default : Bool = false) : Bool
        return default if raw.nil? || raw.empty?
        raw == "true" || raw == "True" || raw == "yes"
      end
    end
  end
end
