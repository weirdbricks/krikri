require "../spec_helper"
require "../../src/krikri/plugin_helpers/selinux_config"

# ansible.posix.selinux's argument rules, ported from the real module's
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
    it "requires state (real argument_spec: required=True)" do
      Krikri::PluginHelpers::SelinuxConfig.state_validation_error(nil)
        .should eq("missing required arguments: state")
    end

    it "rejects values outside real's choices" do
      Krikri::PluginHelpers::SelinuxConfig.state_validation_error("krikri_state")
        .should eq("Invalid state: krikri_state. Must be one of: enforcing, permissive, disabled")
    end

    it "accepts each of real's choices" do
      ["enforcing", "permissive", "disabled"].each do |state|
        Krikri::PluginHelpers::SelinuxConfig.state_validation_error(state).should be_nil
      end
    end
  end

  describe ".policy_required?" do
    it "requires policy whenever state is not disabled" do
      ["enforcing", "permissive"].each do |state|
        Krikri::PluginHelpers::SelinuxConfig.policy_required?(state, nil).should be_true
        Krikri::PluginHelpers::SelinuxConfig.policy_required?(state, "").should be_true
      end
    end

    it "does not require policy for state=disabled (real defaults it from config's SELINUXTYPE)" do
      Krikri::PluginHelpers::SelinuxConfig.policy_required?("disabled", nil).should be_false
    end

    it "does not require policy when one is given" do
      Krikri::PluginHelpers::SelinuxConfig.policy_required?("enforcing", "targeted").should be_false
    end
  end

  describe ".policy_exists_error" do
    it "rejects a policy with no policy store under /etc/selinux" do
      Krikri::PluginHelpers::SelinuxConfig.policy_exists_error("krikri_policy")
        .should eq("Policy krikri_policy does not exist in /etc/selinux/")
    end
  end
end
