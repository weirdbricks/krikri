require "../minitest_helper"
require "../../src/krikri/plugin_helpers/podman_image"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# Unit-tests the podman_image reference/creds logic; execution needs a
# real podman host, the command shapes don't.
describe Krikri::PluginHelpers::PodmanImage do
  describe ".build_reference" do
    it "appends the tag to a bare name" do
      Krikri::PluginHelpers::PodmanImage.build_reference("docker.io/library/nginx", "alpine")
        .must_equal("docker.io/library/nginx:alpine")
    end

    it "leaves names with their own tag alone" do
      Krikri::PluginHelpers::PodmanImage.build_reference("docker.io/library/nginx:1.25", "latest")
        .must_equal("docker.io/library/nginx:1.25")
    end

    it "leaves digest references alone" do
      Krikri::PluginHelpers::PodmanImage.build_reference("quay.io/org/img@sha256:abcdef", nil)
        .must_equal("quay.io/org/img@sha256:abcdef")
    end
  end

  describe ".creds_argument" do
    it "builds user:password creds" do
      Krikri::PluginHelpers::PodmanImage.creds_argument("user", "pass")
        .must_equal(" --creds 'user:pass'")
    end

    it "builds user-only creds" do
      Krikri::PluginHelpers::PodmanImage.creds_argument("user", nil)
        .must_equal(" --creds 'user'")
    end

    it "returns empty when no username" do
      Krikri::PluginHelpers::PodmanImage.creds_argument(nil, "pass").must_equal("")
    end
  end
end

describe "containers.podman.podman_image resolution" do
  it "resolves the FQCN and strips the containers.podman prefix" do
    task = Krikri::PlaybookParser.parse_string(
      "- name: Loop test play\n" \
      "  hosts: all\n" \
      "  tasks:\n" \
      "    - name: t\n" \
      "      containers.podman.podman_image:\n" \
      "        name: nginx\n"
    ).plays[0].tasks[0]
    task.module_name.must_equal("containers.podman.podman_image")
    Krikri::PluginManager.simple_plugin_name("containers.podman.podman_image").must_equal("podman_image")
  end
end

# Registered-result shape parity for podman_image, live-verified against
# real ansible-core 2.19.11 + containers.podman 1.17.0: the module's own
# result dict is changed/actions/podman_actions/image/stdout (then
# Ansible's own stdout_lines and failed), with no msg at all on success.
describe "podman_image result shape" do
  def podman_available? : Bool
    PluginSpecHelper.run("podman_image", {
      "name" => "krikri-pi-nosuchimage-#{Process.pid}", "state" => "absent",
    })["failed"]?.try(&.as_bool) == false
  end

  it "matches real's absent-and-missing key set and order" do
    skip "podman not available" unless podman_available?
    result = PluginSpecHelper.run("podman_image", {
      "name" => "docker.io/library/krikri-pi-shape-gone-#{Process.pid}", "state" => "absent",
    })
    result.as_h.keys.to_a.must_equal(
      ["changed", "actions", "podman_actions", "image", "stdout", "stdout_lines", "failed"])
    result["changed"].as_bool.must_equal(false)
    result["image"].as_h.empty?.must_equal(true)
    result["podman_actions"].as_a.map(&.as_s).first.ends_with?("image exists docker.io/library/krikri-pi-shape-gone-#{Process.pid}").must_equal(true)
  end

  it "matches real's present key set and order" do
    skip "podman not available" unless podman_available?
    Process.run("podman", ["tag", "docker.io/library/alpine:latest", "docker.io/library/krikri-pi-shape:1"],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
    begin
      result = PluginSpecHelper.run("podman_image", {
        "name" => "docker.io/library/krikri-pi-shape", "tag" => "1",
      })
      result.as_h.keys.to_a.must_equal(
        ["changed", "actions", "podman_actions", "image", "stdout", "stdout_lines", "failed"])
      result["changed"].as_bool.must_equal(false)
      result["actions"].as_a.must_be_empty
      result["image"].as_a.wont_be_empty
    ensure
      Process.run("podman", ["rmi", "-f", "docker.io/library/krikri-pi-shape:1"],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
    end
  end

  it "matches real's removed key set and order" do
    skip "podman not available" unless podman_available?
    Process.run("podman", ["tag", "docker.io/library/alpine:latest", "docker.io/library/krikri-pi-shape2:1"],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
    begin
      result = PluginSpecHelper.run("podman_image", {
        "name" => "docker.io/library/krikri-pi-shape2", "tag" => "1", "state" => "absent",
      })
      result.as_h.keys.to_a.must_equal(
        ["changed", "actions", "podman_actions", "image", "stdout", "stdout_lines", "failed"])
      result["changed"].as_bool.must_equal(true)
      result["actions"].as_a.map(&.as_s).must_equal(["Removed image docker.io/library/krikri-pi-shape2"])
      result["image"].as_h["state"].as_s.must_equal("Deleted")
    ensure
      Process.run("podman", ["rmi", "-f", "docker.io/library/krikri-pi-shape2:1"],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
    end
  end
end
