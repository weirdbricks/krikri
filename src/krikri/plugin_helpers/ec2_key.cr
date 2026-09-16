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
      record KeyPair, name : String, fingerprint : String, id : String, tags : Hash(String, String), key_type : String do
        # Older DescribeKeyPairs deployments spell the response without
        # keyPairId/tagSet/keyType - tolerate them rather than crashing
        # the parse.
        def self.from_xml(item : XML::Node) : KeyPair
          KeyPair.new(
            name: Ec2Api.text(item, "keyName") || "",
            fingerprint: Ec2Api.text(item, "keyFingerprint") || "",
            id: Ec2Api.text(item, "keyPairId") || "",
            tags: Ec2Api.parse_tags(item),
            key_type: Ec2Api.text(item, "keyType") || "",
          )
        end
      end

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
          KeyPair.from_xml(item)
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
          return Plan.new([] of Ec2Api::Step, false, "key pair already exists", current.fingerprint)
        end

        if current && force
          steps = [Ec2Api::Step.new("DeleteKeyPair", [{"KeyName", name}])]
          msg = "key pair updated"
        else
          steps = [] of Ec2Api::Step
          msg = nil
        end

        if key_material && !key_material.empty?
          steps << Ec2Api::Step.new("ImportKeyPair", [
            {"KeyName", name},
            {"PublicKeyMaterial", key_material},
          ])
        else
          steps << Ec2Api::Step.new("CreateKeyPair", [{"KeyName", name}])
        end

        # Both the create and the import path report the same msg in the
        # real module (create_new_key_pair covers both), unlike the
        # existing-key path which says "already exists".
        Plan.new(steps, true, current ? msg.to_s : "key pair created", nil)
      end

      def self.plan_absent(name : String, existing : Array(KeyPair)) : Plan
        current = existing.find { |keypair| keypair.name == name }
        return Plan.new([] of Ec2Api::Step, false, "key did not exist", nil) unless current

        Plan.new(
          [Ec2Api::Step.new("DeleteKeyPair", [{"KeyName", name}])],
          true,
          "key deleted",
          current.fingerprint,
        )
      end

      private record CreatedKey, name : String, fingerprint : String, private_key : String, key_pair_id : String, key_type : String

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
        check_mode = bool_param(params["_ansible_check_mode"]?)

        plan = if state == "absent"
                 plan_absent(name, existing)
               else
                 plan_present(name, key_material, force, existing)
               end

        if check_mode
          # Real module's check-mode paths return key: None even when the
          # plan would create/import (create_new_key_pair short-circuits
          # with {"changed": True, "key": None, ...}).
          result = PluginResult.new(changed: plan.changed, failed: false, msg: "#{plan.msg} (check mode)")
          result.extra["key"] = JSON.parse("null")
          return result
        end

        created = run_plan(region, credentials, plan)

        result = PluginResult.new(changed: plan.changed, failed: false, msg: plan.msg)
        # Real module always exits with a `key` field - the extracted key
        # dict on state=present, null otherwise (delete_key_pair returns
        # {"key": None, ...} on every branch). Field set mirrors
        # extract_key_data + scrub_none_parameters: private_key only when
        # AWS just returned key material (CreateKeyPair - EC2 never
        # returns it again), type only when the API reported one.
        if state == "present"
          key_data = Hash(String, JSON::Any).new
          if created
            key_data["name"] = JSON.parse(created.name.to_json)
            key_data["fingerprint"] = JSON.parse(created.fingerprint.to_json)
            key_data["id"] = JSON.parse(created.key_pair_id.to_json)
            key_data["tags"] = json_from_string_hash(parse_tags(params))
            key_data["type"] = JSON.parse(created.key_type.to_json) unless created.key_type.empty?
            key_data["private_key"] = JSON.parse(created.private_key.to_json) unless created.private_key.empty?
            result.extra["key"] = JSON.parse(key_data.to_json)
          elsif current = existing.find { |keypair| keypair.name == name }
            key_data["name"] = JSON.parse(current.name.to_json)
            key_data["fingerprint"] = JSON.parse(current.fingerprint.to_json)
            key_data["id"] = JSON.parse(current.id.to_json)
            key_data["tags"] = json_from_string_hash(current.tags)
            key_data["type"] = JSON.parse(current.key_type.to_json) unless current.key_type.empty?
            result.extra["key"] = JSON.parse(key_data.to_json)
          else
            result.extra["key"] = JSON.parse("null")
          end
        else
          result.extra["key"] = JSON.parse("null")
        end
        apply_tags(region, credentials, created, parse_tags(params)) if created
        result
      rescue ex : Ec2Api::Error
        PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
      end

      private def self.json_from_string_hash(hash : Hash(String, String)) : JSON::Any
        JSON.parse(hash.to_json)
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
              key_type: Ec2Api.text(root, "keyType") || "",
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
