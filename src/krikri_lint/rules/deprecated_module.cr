module Krikri
  module Lint
    # Upstream parity: ansible-lint's deprecated-module rule (severity
    # HIGH, tags deprecations). Upstream keeps this list by hand instead
    # of reading ansible's deprecation metadata, so it is mirrored here.
    class DeprecatedModuleRule < Rule
      MODULES = %w[
        accelerate aos_asn_pool aos_blueprint aos_blueprint_param
        aos_blueprint_virtnet aos_device aos_external_router aos_ip_pool
        aos_logical_device aos_logical_device_map aos_login aos_rack_type
        aos_template azure cl_bond cl_bridge cl_img_install cl_interface
        cl_interface_policy cl_license cl_ports cs_nic docker ec2_ami_find
        ec2_ami_search ec2_remote_facts ec2_vpc kubernetes netscaler
        nxos_ip_interface nxos_mtu nxos_portchannel nxos_switchport oc
        panos_nat_policy panos_security_policy vsphere_guest win_msi include
      ]

      def id : String
        "deprecated-module"
      end

      def severity : Severity
        Severity::HIGH
      end

      def tags : Array(String)
        ["deprecations"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Task-oriented: violations belong to an enclosing task, so a
      # `# noqa:` anywhere in that task's body suppresses them.
      def task_scoped? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          # Upstream matches `__ansible_module__`, the name as written, so an
          # `ansible.legacy.docker:`/`ansible.builtin.docker:` task does not
          # match the bare `docker` entry (verified against 25.2.1); stripping
          # the prefix first would fire where upstream stays silent.
          name = task.module_name
          next unless MODULES.includes?(name)
          violations << Violation.new(file.path, task.line, 0, id, severity,
            "Deprecated module. #{name}", task.line)
        end
      end
    end
  end
end
