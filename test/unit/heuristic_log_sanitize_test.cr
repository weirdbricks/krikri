require "../minitest_helper"
require "../../src/krikri/plugin_helpers/heuristic_log_sanitize"

# AnsibleModule.run_command sanitizes a failed command's msg with
# module_utils/basic.py's heuristic_log_sanitize (the raw stderr stays
# raw in the result's own stderr key). Expectations below were produced
# by that function itself (live-verified against ansible-core 2.21.6).
describe "HeuristicLogSanitize" do
  it "drops everything between a URL scheme and a later quote-package@version (issue #1372)" do
    Krikri::PluginHelpers::HeuristicLogSanitize.sanitize(
      "npm ERR! 404 Not Found - GET https://registry.npmjs.org/jtzgdz - Not found\n" \
      "npm ERR! 404 \nnpm ERR! 404  'jtzgdz@hcxjhw' is not in this registry.\n" \
      "npm ERR! 404 \nnpm ERR! 404 Note that you can also install from a")
      .must_equal(
        "npm ERR! 404 Not Found - GET https:********@hcxjhw' is not in this registry.\n" \
        "npm ERR! 404 \nnpm ERR! 404 Note that you can also install from a")
  end

  it "masks the password of a URL-style credential" do
    Krikri::PluginHelpers::HeuristicLogSanitize
      .sanitize("visit http://user:pass@host/path now")
      .must_equal("visit http://user:********@host/path now")
  end

  it "masks ssh-style user:pass@host" do
    Krikri::PluginHelpers::HeuristicLogSanitize
      .sanitize("ssh user:secret@example.com said no")
      .must_equal("ssh user:********@example.com said no")
  end

  it "leaves text without an @ untouched" do
    Krikri::PluginHelpers::HeuristicLogSanitize
      .sanitize("nothing to hide here")
      .must_equal("nothing to hide here")
  end

  it "rewinds to the start of the string when there is no URL scheme" do
    Krikri::PluginHelpers::HeuristicLogSanitize
      .sanitize("a@b and c:d@e")
      .must_equal("a@b and c:********@e")
  end
end
