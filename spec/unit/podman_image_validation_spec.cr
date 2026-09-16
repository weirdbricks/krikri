require "../spec_helper"

# Pins plugins/podman_image.cr's argument-validation surface against real
# containers.podman.podman_image's AnsibleModule setup (source-verified
# against the module's main() argument_spec; live-diffed vs real
# ansible-playbook via the podman-diff podman_image_edge_cases harness -
# real runs all of this BEFORE the podman executable probe, the only
# byte-comparable surface without a podman binary):
#
# - required name
# - state choices render in declaration order (absent, present, build,
#   quadlet)
# - pull/push/force/validate_certs bool conversion
# - username/password required-together, auth_file/username and
#   arch/platform mutual exclusions
# - build (it has suboptions) fails a non-dict with the BARE
#   check_type_dict wording, not the wrapped "argument ... is of type" one
# - the spec is the GALAXY-release one: pull_policy/retry/retry_delay are
#   main-only, real rejects them with Unsupported parameters (live-
#   verified); unsupported params render spec keys sorted then ONE
#   trailing parenthetical holding every alias sorted
describe "podman_image plugin argument validation" do
  it "fails without name" do
    result = PluginSpecHelper.run("podman_image", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name")
  end

  it "fails an invalid state choice in declaration order" do
    result = PluginSpecHelper.run("podman_image", {"name" => "krikri/img", "state" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: absent, present, build, quadlet, got: banana")
  end

  it "rejects pull_policy as unsupported (galaxy-release spec has no such param)" do
    result = PluginSpecHelper.run("podman_image", {"name" => "krikri/img", "pull_policy" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should start_with("Unsupported parameters for (containers.podman.podman_image) module: pull_policy. " \
                                         "Supported parameters include: arch, auth_file, build, ca_cert_dir, executable, " \
                                         "force, name, password, path, platform, pull, pull_extra_args, push, push_args, " \
                                         "quadlet_dir, quadlet_file_mode, quadlet_filename, quadlet_options, state, tag, " \
                                         "username, validate_certs (")
  end

  it "fails a non-boolean force with parameters.py wording" do
    result = PluginSpecHelper.run("podman_image", {"name" => "krikri/img", "force" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("argument 'force' is of type <class 'str'> and we were unable to convert to bool: " \
                                      "The value 'banana' is not a valid boolean.  Valid booleans include: ")
  end

  it "fails username without password (required_together)" do
    result = PluginSpecHelper.run("podman_image", {"name" => "krikri/img", "username" => "krikri"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are required together: username, password")
  end

  it "fails auth_file + username (mutually exclusive)" do
    result = PluginSpecHelper.run("podman_image", {
      "name"      => "krikri/img",
      "auth_file" => "/tmp/auth.json",
      "username"  => "krikri",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: auth_file|username")
  end

  it "fails arch + platform (mutually exclusive)" do
    result = PluginSpecHelper.run("podman_image", {
      "name"     => "krikri/img",
      "arch"     => "amd64",
      "platform" => "linux/amd64",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: arch|platform")
  end

  it "fails a plain-string build with the bare check_type_dict wording" do
    result = PluginSpecHelper.run("podman_image", {"name" => "krikri/img", "build" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("dictionary requested, could not parse JSON or key=value")
  end

  it "fails a non-integer retry as unsupported (galaxy-release spec has no such param)" do
    result = PluginSpecHelper.run("podman_image", {"name" => "krikri/img", "retry" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should start_with("Unsupported parameters for (containers.podman.podman_image) module: retry. ")
  end

  it "rejects unsupported parameters with the all-aliases parenthetical" do
    result = PluginSpecHelper.run("podman_image", {"name" => "krikri/img", "banana" => "x"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should end_with("Supported parameters include: arch, auth_file, build, ca_cert_dir, executable, " \
                                       "force, name, password, path, platform, pull, pull_extra_args, push, push_args, " \
                                       "quadlet_dir, quadlet_file_mode, quadlet_filename, quadlet_options, state, tag, " \
                                       "username, validate_certs (authfile, build_args, buildargs, tls_verify, tlsverify).")
  end
end
