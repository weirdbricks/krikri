require "../minitest_helper"
require "../../src/krikri/plugin_helpers/selinux_config"

# ansible.posix.selinux's argument rules, behavior matched to the Ansible module's
# main() - see PluginHelpers::SelinuxConfig's class docs for the order
# (arg-spec state check, then the /etc/selinux/config existence failure,
# then policy-required-unless-disabled, then the policy-store existence
# check on the non-check-mode write path). Found via the podman-diff
# harness: krikri treated state as optional (silently succeeding with
# changed=false), accepted state=enforcing with no policy (writing the
# config instead of failing), and rewrote SELINUXTYPE to a policy that
# has no policy store.
describe Krikri::PluginHelpers::SelinuxConfig do
  describe ".state_validation_error" do
    it "requires state (Ansible's argument_spec: required=True)" do
      Krikri::PluginHelpers::SelinuxConfig.state_validation_error(nil)
        .must_equal("missing required arguments: state")
    end

    it "rejects values outside Ansible's choices" do
      Krikri::PluginHelpers::SelinuxConfig.state_validation_error("krikri_state")
        .must_equal("Invalid state: krikri_state. Must be one of: enforcing, permissive, disabled")
    end

    it "accepts each of Ansible's choices" do
      ["enforcing", "permissive", "disabled"].each do |state|
        Krikri::PluginHelpers::SelinuxConfig.state_validation_error(state).must_be_nil
      end
    end
  end

  describe ".policy_required?" do
    it "requires policy whenever state is not disabled" do
      ["enforcing", "permissive"].each do |state|
        Krikri::PluginHelpers::SelinuxConfig.policy_required?(state, nil).must_equal(true)
        Krikri::PluginHelpers::SelinuxConfig.policy_required?(state, "").must_equal(true)
      end
    end

    it "does not require policy for state=disabled (real defaults it from config's SELINUXTYPE)" do
      Krikri::PluginHelpers::SelinuxConfig.policy_required?("disabled", nil).must_equal(false)
    end

    it "does not require policy when one is given" do
      Krikri::PluginHelpers::SelinuxConfig.policy_required?("enforcing", "targeted").must_equal(false)
    end
  end

  describe ".policy_exists_error" do
    it "rejects a policy with no policy store under /etc/selinux" do
      Krikri::PluginHelpers::SelinuxConfig.policy_exists_error("krikri_policy")
        .must_equal("Policy krikri_policy does not exist in /etc/selinux/")
    end
  end
end
