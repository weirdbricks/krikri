require "../minitest_helper"
require "../../src/krikri/plugin_helpers/getfqdn"

# The hostname plugin's returned ansible_fqdn must come from
# socket.getfqdn()'s REVERSE-lookup algorithm, not `hostname -f`'s
# forward lookup of the name itself. oasis_roles.hostname sets a short
# hostname and then rewrites /etc/hosts so 127.0.0.1 carries that name;
# on the role's warm run real ansible reverse-resolves the live hostname
# and reports ansible_fqdn "localhost", which its next blockinfile task
# then writes into the block - a change krikri's `hostname -f` echo kept
# masking as ok (issue #585). These pin the parse of the reverse-lookup
# output; the shelling-out half of the algorithm stays a live-host
# concern, same convention as FactsGatherer's #detect_virtualization.
describe Krikri::PluginHelpers::Getfqdn do
  describe "#from_getent_hosts" do
    it "reports localhost for a 127.0.0.1 reverse line holding only the short name" do
      # The issue's exact shape after the role's cold run trims the
      # block down: the only name on the line is dotless "localhost",
      # and Python's getfqdn returns it verbatim (its all-dotless
      # fallback is the reverse line's own canonical name) - NOT the
      # machine's hostname.
      Krikri::PluginHelpers::Getfqdn.from_getent_hosts("127.0.0.1 localhost").must_equal("localhost")
    end

    it "prefers the first dot-qualified name over the dotless canonical one" do
      Krikri::PluginHelpers::Getfqdn.from_getent_hosts("127.0.0.1 localhost localhost.localdomain").must_equal("localhost.localdomain")
    end

    it "falls back to the reverse line's canonical name when every name is dotless" do
      Krikri::PluginHelpers::Getfqdn.from_getent_hosts("127.0.1.1 testhost").must_equal("testhost")
    end

    it "returns empty for a bare address with no names at all" do
      Krikri::PluginHelpers::Getfqdn.from_getent_hosts("127.0.0.1").must_equal("")
    end
  end

  describe "#lookup" do
    it "returns empty when there is no resolver answer at all" do
      # An empty name gets no resolver answer on any host (getent exits
      # nonzero with no output), so this exercises the no-answer path -
      # the one the caller maps to its live-hostname fallback - without
      # depending on this machine's /etc/hosts contents.
      Krikri::PluginHelpers::Getfqdn.lookup("").must_equal("")
    end
  end
end
