require "../spec_helper"

# pip: actually installing/uninstalling packages needs a real pip
# binary and network access, and mutates the machine running the test
# suite - these specs exercise validation only (safe, no real
# execution), matching the same convention apt.cr's own fixes use
# (spec/integration/apt_repository_spec.cr's own comment, and
# haproxy-certbot-benchmark-round.md's documented rationale for why
# cron.cr's user-crontab path has no spec either).
describe "pip plugin" do
  it "fails with a clear message when neither name nor requirements is given" do
    result = PluginSpecHelper.run("pip", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("name or requirements")
  end
end
