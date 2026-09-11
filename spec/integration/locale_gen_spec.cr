require "../spec_helper"

# locale_gen's parameter-validation failures, exercised before anything
# shells out or reads /etc/locale.gen. Actually generating or removing
# a locale mutates the host's locale state and belongs to the live
# benchmark rounds.
describe "locale_gen plugin" do
  it "fails when name is missing" do
    result = PluginSpecHelper.run("locale_gen", {"state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("name")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("locale_gen", {"name" => "en_US.UTF-8", "state" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("state")
  end

  # The mechanism probe is the real module's first host-dependent step;
  # when neither /etc/locale.gen nor /var/lib/locales/supported.d
  # exists, that failure must surface before any availability check.
  it "fails cleanly when the locales package is not installed", tags: "needs_locales" do
    next if File.exists?("/etc/locale.gen") || File.exists?("/var/lib/locales/supported.d")

    result = PluginSpecHelper.run("locale_gen", {"name" => "en_US.UTF-8", "state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Is the package")
  end
end
