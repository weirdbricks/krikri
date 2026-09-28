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
