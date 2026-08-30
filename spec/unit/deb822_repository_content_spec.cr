require "../spec_helper"
require "../../src/krikri/plugin_helpers/deb822_repository_content"

# Real bug found via a proactive scope-cut audit: most DEB822 keys
# (trusted/enabled/allow_insecure/allow_downgrade_to_insecure/
# allow_weak/pdiffs/by_hash/check_date/check_valid_until/languages/
# targets/date_max_future) were entirely unimplemented, and the fields
# that WERE implemented were written in a fixed order that didn't match
# real Ansible's own field ordering at all.
describe Krikri::PluginHelpers::Deb822RepositoryContent do
  describe ".render" do
    it "sorts fields alphabetically by the underlying param name, matching real Ansible's own repo: output byte-for-byte" do
      # This exact fixture/expected-output pair was captured directly
      # from a real `ansible-playbook -vvv --check` run's own `repo:`
      # return value against the identical params - not derived from
      # source alone.
      fields = {
        "allow_insecure"  => "Allow-Insecure: no",
        "components"      => "Components: main",
        "date_max_future" => "Date-Max-Future: 86400",
        "enabled"         => "Enabled: yes",
        "languages"       => "Languages: en",
        "name"            => "X-Repolib-Name: krikri-playbook-spec-test",
        "pdiffs"          => "Pdiffs: no",
        "suites"          => "Suites: stable",
        "targets"         => "Targets: deb",
        "trusted"         => "Trusted: yes",
        "types"           => "Types: deb",
        "uris"            => "URIs: https://example.com/repo",
      }

      Krikri::PluginHelpers::Deb822RepositoryContent.render(fields).should eq(
        "Allow-Insecure: no\n" \
        "Components: main\n" \
        "Date-Max-Future: 86400\n" \
        "Enabled: yes\n" \
        "Languages: en\n" \
        "X-Repolib-Name: krikri-playbook-spec-test\n" \
        "Pdiffs: no\n" \
        "Suites: stable\n" \
        "Targets: deb\n" \
        "Trusted: yes\n" \
        "Types: deb\n" \
        "URIs: https://example.com/repo\n"
      )
    end

    it "omits fields not given, without leaving gaps" do
      fields = {"types" => "Types: deb", "uris" => "URIs: https://example.com/repo", "suites" => "Suites: stable", "name" => "X-Repolib-Name: x"}

      Krikri::PluginHelpers::Deb822RepositoryContent.render(fields).should eq(
        "X-Repolib-Name: x\nSuites: stable\nTypes: deb\nURIs: https://example.com/repo\n"
      )
    end
  end
end
