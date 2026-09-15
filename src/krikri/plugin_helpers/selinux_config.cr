module Krikri
  module PluginHelpers
    # SelinuxConfig - the pure validation logic of ansible.posix.selinux,
    # split out of the plugin so the arg-spec rules are unit-testable
    # without a host that has /etc/selinux/config. Ported from the real
    # module's main() (ansible-collections/ansible.posix):
    #
    # 1. `state` is REQUIRED (choices enforcing/permissive/disabled) -
    #    enforced by AnsibleModule argument-spec at module init, before
    #    anything else.
    # 2. The /etc/selinux/config existence failure comes next
    #    (unconditional - there is no "SELinux not compiled in, treat as
    #    no-op" special case; see plugins/selinux.cr's class docs).
    # 3. `policy` is REQUIRED whenever `state` is not "disabled"
    #    ("Policy is required if state is not 'disabled'"); when state IS
    #    disabled and policy is omitted, real defaults it from the
    #    config's SELINUXTYPE.
    # 4. A policy whose /etc/selinux/<policy>/policy path does not exist
    #    is rejected ("Policy <p> does not exist in /etc/selinux/") - but
    #    only when the module is actually about to rewrite SELINUXTYPE
    #    (set_config_policy), never in check mode, which exits
    #    changed=true before reaching it.
    module SelinuxConfig
      VALID_STATES = ["enforcing", "permissive", "disabled"]

      def self.state_validation_error(state : String?) : String?
        return "missing required arguments: state" unless state
        unless VALID_STATES.includes?(state)
          return "Invalid state: #{state}. Must be one of: #{VALID_STATES.join(", ")}"
        end
        nil
      end

      def self.policy_required?(state : String, policy : String?) : Bool
        # Python's falsy-empty-string: real's `if not policy:` treats ""
        # the same as None.
        state != "disabled" && (policy.nil? || policy.empty?)
      end

      def self.policy_exists_error(policy : String) : String?
        unless File.exists?("/etc/selinux/#{policy}/policy")
          return "Policy #{policy} does not exist in /etc/selinux/"
        end
        nil
      end
    end
  end
end
