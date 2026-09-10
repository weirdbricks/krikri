require "json"
require "../base_plugin"

module Krikri
  module PluginHelpers
    # Decision logic for amazon.aws.ec2_key - manage an EC2 SSH key pair
    # (create a new key pair, import an existing public key, delete).
    #
    # The plan functions take the module params plus the ALREADY-FETCHED
    # DescribeKeyPairs result and return the exact sequence of mutating
    # EC2 API calls to make (as Ec2Api::Step records) plus the changed
    # flag and message. Keeping the wire calls out is what lets specs
    # exercise every decision branch against canned XML with no network.
    #
    # Behavior mirrors the real module's key_pair module_utils:
    # - state=present, no key_material: create a new key pair unless one
    #   with the same name exists (or force=true, which deletes and
    #   recreates). The CreateKeyPair response's private key is the only
    #   chance to capture it - EC2 never returns it again.
    # - state=present with key_material: import the public key unless the
    #   name already exists (or force=true).
    # - state=absent: delete if it exists, no-op otherwise.
    module Ec2Key
      record KeyPair, name : String, fingerprint : String

      record Plan,
        steps : Array(Ec2Api::Step),
        changed : Bool,
        msg : String,
        fingerprint : String?

      # DescribeKeyPairsResponse -> key list. The response wraps each key
      # in keyPairsSet/item (the older anon-2011 spelling was
      # keyPairs/item; both seen in the wild, so accept both).
      def self.parse_key_pairs(root : XML::Node) : Array(KeyPair)
        set = Ec2Api.child(root, "keyPairsSet") || Ec2Api.child(root, "keyPairs")
        return [] of KeyPair unless set

        set.children.select { |node| node.name == "item" }.map do |item|
          KeyPair.new(
            name: Ec2Api.text(item, "keyName") || "",
            fingerprint: Ec2Api.text(item, "keyFingerprint") || "",
          )
        end
      end

      # Filter.1.Name=key-name pairs for the name lookup the plugin
      # performs before planning.
      def self.describe_filter(name : String) : Array(Tuple(String, String))
        Ec2Api.filter_params([{"key-name", [name]}])
      end

      def self.plan_present(name : String, key_material : String?, force : Bool, existing : Array(KeyPair)) : Plan
        current = existing.find { |keypair| keypair.name == name }

        if current && !force
          return Plan.new([] of Ec2Api::Step, false, "key pair #{name} already exists", current.fingerprint)
        end

        if current && force
          steps = [Ec2Api::Step.new("DeleteKeyPair", [{"KeyName", name}])]
          msg = "key pair #{name} force-replaced"
        else
          steps = [] of Ec2Api::Step
          msg = nil
        end

        if key_material && !key_material.empty?
          steps << Ec2Api::Step.new("ImportKeyPair", [
            {"KeyName", name},
            {"PublicKeyMaterial", key_material},
          ])
          msg = "key pair #{name} imported"
        else
          steps << Ec2Api::Step.new("CreateKeyPair", [{"KeyName", name}])
          msg = "key pair #{name} created"
        end

        Plan.new(steps, true, msg.to_s, nil)
      end

      def self.plan_absent(name : String, existing : Array(KeyPair)) : Plan
        current = existing.find { |keypair| keypair.name == name }
        return Plan.new([] of Ec2Api::Step, false, "key pair #{name} already absent", nil) unless current

        Plan.new(
          [Ec2Api::Step.new("DeleteKeyPair", [{"KeyName", name}])],
          true,
          "key pair #{name} deleted",
          current.fingerprint,
        )
      end

      private record CreatedKey, name : String, fingerprint : String, private_key : String, key_pair_id : String

      # Full module run: params in (the same string-hash the plugin
      # binary receives), result out. The plugin binary is a one-line
      # wrapper around this; specs drive it through the Ec2Api transport
      # seam instead of the real network.
      def self.run(params : Hash(String, String)) : Krikri::PluginResult
        name = params["name"]?
        if name.nil? || name.empty?
          return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
        end

        state = params["state"]? || "present"
        unless ["present", "absent"].includes?(state)
          return PluginResult.new(changed: false, failed: true, msg: "state must be present or absent, got #{state}")
        end

        region = Ec2Api.resolve_region(params["region"]?)
        credentials = Ec2Api.resolve_credentials

        existing = describe_key_pairs(region, credentials, name)
        key_material = params["key_material"]?
        force = bool_param(params["force"]?)
        check_mode = bool_param(params["check_mode"]?)

        plan = if state == "absent"
                 plan_absent(name, existing)
               else
                 plan_present(name, key_material, force, existing)
               end

        return PluginResult.new(changed: plan.changed, failed: false, msg: "#{plan.msg} (check mode)") if check_mode

        created = run_plan(region, credentials, plan)

        result = PluginResult.new(changed: plan.changed, failed: false, msg: plan.msg)
        result.extra["name"] = JSON.parse(name.to_json)
        fingerprint = created.try(&.fingerprint) || plan.fingerprint || ""
        result.extra["fingerprint"] = JSON.parse(fingerprint.to_json)
        private_key = plan.changed && created ? created.try(&.private_key) || "" : ""
        result.extra["private_key"] = JSON.parse(private_key.to_json)
        apply_tags(region, credentials, created, parse_tags(params)) if created
        result
      rescue ex : Ec2Api::Error
        PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
      end

      private def self.bool_param(raw : String?) : Bool
        raw == "true" || raw == "True" || raw == "yes"
      end

      private def self.describe_key_pairs(region : String, credentials : Ec2Api::Credentials, name : String) : Array(KeyPair)
        params = Ec2Api.to_form_params(describe_filter(name))
        root = Ec2Api.call(region, "DescribeKeyPairs", params, credentials)
        parse_key_pairs(root)
      end

      private def self.run_plan(region : String, credentials : Ec2Api::Credentials, plan : Plan) : CreatedKey?
        created = nil
        plan.steps.each do |step|
          root = Ec2Api.call(region, step.action, Ec2Api.to_form_params(step.params), credentials)
          if step.action == "CreateKeyPair" || step.action == "ImportKeyPair"
            created = CreatedKey.new(
              name: Ec2Api.text(root, "keyName") || "",
              fingerprint: Ec2Api.text(root, "keyFingerprint") || "",
              private_key: Ec2Api.text(root, "keyMaterial") || "",
              key_pair_id: Ec2Api.text(root, "keyPairId") || "",
            )
          end
        end
        created
      end

      private def self.apply_tags(region : String, credentials : Ec2Api::Credentials, created : CreatedKey, tags : Hash(String, String)) : Nil
        return if tags.empty? || created.key_pair_id.empty?

        params = [{"ResourceId.1", created.key_pair_id}] + Ec2Api.tag_params(tags)
        Ec2Api.call(region, "CreateTags", Ec2Api.to_form_params(params), credentials)
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
