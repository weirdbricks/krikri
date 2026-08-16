require "../spec_helper"

# alternatives: actually running update-alternatives needs root
# (writes to /etc/alternatives), so these specs exercise validation
# only (safe, no real execution), matching the same convention
# npm.cr/make.cr's own specs use.
#
# Live-verified separately (not in this spec, to avoid needing root in
# CI): round 103's robertdebock.alternatives benchmark - installed a
# fake alternative (`update-alternatives --install`) and selected it
# (`--set`), byte-identical `update-alternatives --display` output to
# real Ansible afterward, and a warm rerun correctly reported
# changed: false (fixed a real idempotency bug first - Crystal's `/m`
# regex flag enables BOTH multiline anchors AND dot-matches-newline
# together, unlike Python's `re.MULTILINE`, so the original `(.*)$`
# captures were greedily swallowing the rest of `update-alternatives
# --display`'s multi-line output instead of stopping at end-of-line;
# fixed by using `([^\n]*)$` instead of `(.*)$`).
describe "alternatives plugin" do
  it "fails when name is missing" do
    result = PluginSpecHelper.run("alternatives", {"path" => "/bin/true"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("name is required")
  end
end
