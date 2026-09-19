require "./aws_module_args"

module Krikri
  module PluginHelpers
    # The merged argument specs (AWS base spec + module params) for the
    # seven amazon.aws modules krikri reimplements natively, in real
    # declaration order (base first, then the module's own), plus the
    # module-level mutually_exclusive / required_one_of / required_if
    # groups. Ported from amazon.aws 11.4.0's module sources; the
    # unsupported-parameter messages render the sorted key/alias lists,
    # so the order here only drives WHICH error surfaces first.
    module AwsModuleSpecs
      EC2_KEY = AwsModuleArgs::Spec.new(
        module_name: "amazon.aws.ec2_key",
        args: AwsModuleArgs.base_args.merge!({
          "name"         => AwsModuleArgs::Arg.new(required: true),
          "key_material" => AwsModuleArgs::Arg.new,
          "force"        => AwsModuleArgs::Arg.new(type: "bool"),
          "state"        => AwsModuleArgs::Arg.new(choices: %w[present absent]),
          "tags"         => AwsModuleArgs::Arg.new(type: "dict", aliases: ["resource_tags"]),
          "purge_tags"   => AwsModuleArgs::Arg.new(type: "bool"),
          "key_type"     => AwsModuleArgs::Arg.new(choices: %w[rsa ed25519]),
          "file_name"    => AwsModuleArgs::Arg.new(type: "path"),
        }),
        mutually_exclusive: [["key_material", "key_type"]],
      )

      EC2_AMI_INFO = AwsModuleArgs::Spec.new(
        module_name: "amazon.aws.ec2_ami_info",
        args: AwsModuleArgs.base_args.merge!({
          "describe_image_attributes" => AwsModuleArgs::Arg.new(type: "bool"),
          "executable_users"          => AwsModuleArgs::Arg.new(type: "list", aliases: ["executable_user"]),
          "filters"                   => AwsModuleArgs::Arg.new(type: "dict"),
          "image_ids"                 => AwsModuleArgs::Arg.new(type: "list", aliases: ["image_id"]),
          "owners"                    => AwsModuleArgs::Arg.new(type: "list", aliases: ["owner"]),
        }),
      )

      EC2_VPC_NET_INFO = AwsModuleArgs::Spec.new(
        module_name: "amazon.aws.ec2_vpc_net_info",
        args: AwsModuleArgs.base_args.merge!({
          "vpc_ids" => AwsModuleArgs::Arg.new(type: "list"),
          "filters" => AwsModuleArgs::Arg.new(type: "dict"),
        }),
      )

      EC2_VPC_SUBNET_INFO = AwsModuleArgs::Spec.new(
        module_name: "amazon.aws.ec2_vpc_subnet_info",
        args: AwsModuleArgs.base_args.merge!({
          "subnet_ids" => AwsModuleArgs::Arg.new(type: "list", aliases: ["subnet_id"]),
          "filters"    => AwsModuleArgs::Arg.new(type: "dict"),
        }),
      )

      IAM_USER_INFO = AwsModuleArgs::Spec.new(
        module_name: "amazon.aws.iam_user_info",
        args: AwsModuleArgs.base_args.merge!({
          "name"        => AwsModuleArgs::Arg.new(aliases: ["user_name"]),
          "group"       => AwsModuleArgs::Arg.new(aliases: ["group_name"]),
          "path_prefix" => AwsModuleArgs::Arg.new(aliases: ["path", "prefix"]),
        }),
        mutually_exclusive: [["group", "path_prefix"]],
      )

      SG_RULE_SPEC = AwsModuleArgs::SubSpec.new(
        args: {
          "rule_desc"  => AwsModuleArgs::SubArg.new,
          "cidr_ip"    => AwsModuleArgs::SubArg.new(type: "list"),
          "cidr_ipv6"  => AwsModuleArgs::SubArg.new(type: "list"),
          "ip_prefix"  => AwsModuleArgs::SubArg.new(type: "list"),
          "group_id"   => AwsModuleArgs::SubArg.new(type: "list"),
          "group_name" => AwsModuleArgs::SubArg.new(type: "list"),
          "group_desc" => AwsModuleArgs::SubArg.new,
          "proto"      => AwsModuleArgs::SubArg.new,
          "ports"      => AwsModuleArgs::SubArg.new(type: "list"),
          "from_port"  => AwsModuleArgs::SubArg.new(type: "int"),
          "to_port"    => AwsModuleArgs::SubArg.new(type: "int"),
          "icmp_type"  => AwsModuleArgs::SubArg.new(type: "int"),
          "icmp_code"  => AwsModuleArgs::SubArg.new(type: "int"),
        },
        mutually_exclusive: [
          ["ports", "to_port"], ["ports", "from_port"],
          ["ports", "icmp_type"], ["ports", "icmp_code"],
          ["icmp_type", "to_port"], ["icmp_code", "to_port"],
          ["icmp_type", "from_port"], ["icmp_code", "from_port"],
        ],
        required_one_of: [["group_id", "group_name", "cidr_ip", "cidr_ipv6", "ip_prefix"]],
        required_by: {"icmp_code" => ["icmp_type"]} of String => Array(String),
      )

      EC2_SECURITY_GROUP = AwsModuleArgs::Spec.new(
        module_name: "amazon.aws.ec2_security_group",
        args: AwsModuleArgs.base_args.merge!({
          "name"               => AwsModuleArgs::Arg.new,
          "group_id"           => AwsModuleArgs::Arg.new,
          "description"        => AwsModuleArgs::Arg.new,
          "vpc_id"             => AwsModuleArgs::Arg.new,
          "rules"              => AwsModuleArgs::Arg.new(type: "list"),
          "rules_egress"       => AwsModuleArgs::Arg.new(type: "list", aliases: ["egress_rules"]),
          "state"              => AwsModuleArgs::Arg.new(choices: %w[present absent]),
          "purge_rules"        => AwsModuleArgs::Arg.new(type: "bool"),
          "purge_rules_egress" => AwsModuleArgs::Arg.new(type: "bool", aliases: ["purge_egress_rules"]),
          "tags"               => AwsModuleArgs::Arg.new(type: "dict", aliases: ["resource_tags"]),
          "purge_tags"         => AwsModuleArgs::Arg.new(type: "bool"),
        }),
        required_one_of: [["name", "group_id"]],
        required_if: [{"state", "present", ["name", "description"]}] of Tuple(String, String, Array(String)),
        sub: {
          "rules"        => SG_RULE_SPEC,
          "rules_egress" => SG_RULE_SPEC,
        },
      )

      EC2_INSTANCE = AwsModuleArgs::Spec.new(
        module_name: "amazon.aws.ec2_instance",
        args: AwsModuleArgs.base_args.merge!({
          "state"                                => AwsModuleArgs::Arg.new(choices: %w[present started running stopped restarted rebooted terminated absent]),
          "wait"                                 => AwsModuleArgs::Arg.new(type: "bool"),
          "wait_timeout"                         => AwsModuleArgs::Arg.new(type: "int"),
          "count"                                => AwsModuleArgs::Arg.new(type: "int"),
          "exact_count"                          => AwsModuleArgs::Arg.new(type: "int"),
          "image"                                => AwsModuleArgs::Arg.new(type: "dict"),
          "image_id"                             => AwsModuleArgs::Arg.new,
          "instance_type"                        => AwsModuleArgs::Arg.new,
          "user_data"                            => AwsModuleArgs::Arg.new,
          "aap_callback"                         => AwsModuleArgs::Arg.new(type: "dict", aliases: ["tower_callback"]),
          "ebs_optimized"                        => AwsModuleArgs::Arg.new(type: "bool"),
          "vpc_subnet_id"                        => AwsModuleArgs::Arg.new(aliases: ["subnet_id"]),
          "availability_zone"                    => AwsModuleArgs::Arg.new,
          "security_groups"                      => AwsModuleArgs::Arg.new(type: "list"),
          "security_group"                       => AwsModuleArgs::Arg.new,
          "iam_instance_profile"                 => AwsModuleArgs::Arg.new(aliases: ["instance_role"]),
          "name"                                 => AwsModuleArgs::Arg.new,
          "tags"                                 => AwsModuleArgs::Arg.new(type: "dict", aliases: ["resource_tags"]),
          "purge_tags"                           => AwsModuleArgs::Arg.new(type: "bool"),
          "filters"                              => AwsModuleArgs::Arg.new(type: "dict"),
          "launch_template"                      => AwsModuleArgs::Arg.new(type: "dict"),
          "license_specifications"               => AwsModuleArgs::Arg.new(type: "list"),
          "key_name"                             => AwsModuleArgs::Arg.new,
          "cpu_credit_specification"             => AwsModuleArgs::Arg.new(choices: %w[standard unlimited]),
          "cpu_options"                          => AwsModuleArgs::Arg.new(type: "dict"),
          "tenancy"                              => AwsModuleArgs::Arg.new(choices: %w[dedicated default]),
          "placement_group"                      => AwsModuleArgs::Arg.new,
          "placement"                            => AwsModuleArgs::Arg.new(type: "dict"),
          "instance_initiated_shutdown_behavior" => AwsModuleArgs::Arg.new(choices: %w[stop terminate]),
          "termination_protection"               => AwsModuleArgs::Arg.new(type: "bool"),
          "hibernation_options"                  => AwsModuleArgs::Arg.new(type: "bool"),
          "detailed_monitoring"                  => AwsModuleArgs::Arg.new(type: "bool"),
          "instance_ids"                         => AwsModuleArgs::Arg.new(type: "list"),
          "network"                              => AwsModuleArgs::Arg.new(type: "dict"),
          "volumes"                              => AwsModuleArgs::Arg.new(type: "list"),
          "metadata_options"                     => AwsModuleArgs::Arg.new(type: "dict"),
          "additional_info"                      => AwsModuleArgs::Arg.new,
          "network_interfaces_ids"               => AwsModuleArgs::Arg.new(type: "list"),
          "network_interfaces"                   => AwsModuleArgs::Arg.new(type: "list"),
          "source_dest_check"                    => AwsModuleArgs::Arg.new(type: "bool"),
        }),
        sub: {
          "image" => AwsModuleArgs::SubSpec.new(args: {
            "id"      => AwsModuleArgs::SubArg.new,
            "ramdisk" => AwsModuleArgs::SubArg.new,
            "kernel"  => AwsModuleArgs::SubArg.new,
          }),
          "aap_callback" => AwsModuleArgs::SubSpec.new(args: {
            "windows"         => AwsModuleArgs::SubArg.new(type: "bool"),
            "set_password"    => AwsModuleArgs::SubArg.new,
            "tower_address"   => AwsModuleArgs::SubArg.new,
            "job_template_id" => AwsModuleArgs::SubArg.new,
            "host_config_key" => AwsModuleArgs::SubArg.new,
          }),
          "cpu_options" => AwsModuleArgs::SubSpec.new(args: {
            "core_count"       => AwsModuleArgs::SubArg.new(type: "int", required: true),
            "threads_per_core" => AwsModuleArgs::SubArg.new(type: "int", choices: %w[1 2], required: true),
          }),
          "metadata_options" => AwsModuleArgs::SubSpec.new(args: {
            "http_endpoint"               => AwsModuleArgs::SubArg.new(choices: %w[enabled disabled]),
            "http_put_response_hop_limit" => AwsModuleArgs::SubArg.new(type: "int"),
            "http_tokens"                 => AwsModuleArgs::SubArg.new(choices: %w[optional required]),
            "http_protocol_ipv6"          => AwsModuleArgs::SubArg.new(choices: %w[disabled enabled]),
            "instance_metadata_tags"      => AwsModuleArgs::SubArg.new(choices: %w[disabled enabled]),
          }),
          "placement" => AwsModuleArgs::SubSpec.new(args: {
            "affinity"                => AwsModuleArgs::SubArg.new,
            "availability_zone"       => AwsModuleArgs::SubArg.new,
            "group_name"              => AwsModuleArgs::SubArg.new,
            "host_id"                 => AwsModuleArgs::SubArg.new,
            "host_resource_group_arn" => AwsModuleArgs::SubArg.new,
            "partition_number"        => AwsModuleArgs::SubArg.new(type: "int"),
            "tenancy"                 => AwsModuleArgs::SubArg.new(choices: %w[dedicated default host]),
          }),
          "license_specifications" => AwsModuleArgs::SubSpec.new(args: {
            "license_configuration_arn" => AwsModuleArgs::SubArg.new(required: true),
          }),
          "network_interfaces_ids" => AwsModuleArgs::SubSpec.new(args: {
            "id"           => AwsModuleArgs::SubArg.new(required: true),
            "device_index" => AwsModuleArgs::SubArg.new(type: "int"),
          }),
          "network_interfaces" => AwsModuleArgs::SubSpec.new(args: {
            "assign_public_ip"      => AwsModuleArgs::SubArg.new(type: "bool"),
            "private_ip_address"    => AwsModuleArgs::SubArg.new,
            "ipv6_addresses"        => AwsModuleArgs::SubArg.new(type: "list"),
            "description"           => AwsModuleArgs::SubArg.new,
            "private_ip_addresses"  => AwsModuleArgs::SubArg.new(type: "list"),
            "subnet_id"             => AwsModuleArgs::SubArg.new,
            "delete_on_termination" => AwsModuleArgs::SubArg.new(type: "bool"),
            "device_index"          => AwsModuleArgs::SubArg.new(type: "int"),
            "groups"                => AwsModuleArgs::SubArg.new(type: "list"),
          }),
          # elements=dict with NO options= - only the per-element
          # dict-conversion check applies (the "Elements value for
          # option" wording).
          "volumes" => AwsModuleArgs::SubSpec.new(args: {} of String => AwsModuleArgs::SubArg),
        },
      )
    end
  end
end
