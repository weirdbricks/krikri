require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# community.general shipped the docker_* modules before they moved to
# community.docker, and its own meta/runtime.yml still redirects those
# pre-2.0 FQCNs, so real resolves the spelling and RUNS the module.
# salessandri.monero writes `community.general.docker_container:`;
# without the redirect krikri skipped the task as an unavailable module
# (recap skipped=1, exit 4 in --check mode) where real ran it and hit its
# own docker connection failure (failed=1, exit 2).
describe "community.general docker_* redirects" do
  {% for spelling, resolved in {
                                 "community.general.docker_container"    => "community.docker.docker_container",
                                 "community.general.docker_image"        => "community.docker.docker_image",
                                 "community.general.docker_network"      => "community.docker.docker_network",
                                 "community.general.docker_network_info" => "community.docker.docker_network_info",
                               } %}
    it "resolves {{ spelling.id }} onto {{ resolved.id }}" do
      Krikri::PlaybookParser.resolve_module_name({{ spelling }}).must_equal({{ resolved }})
    end
  {% end %}
end
