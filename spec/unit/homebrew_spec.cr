require "../spec_helper"
require "../../src/krikri/plugin_helpers/homebrew"
require "json"

# Unit-tests the homebrew logic against real community.general.homebrew's
# own behavior (name matching and installed/outdated rules per
# _get_packages_info/_extract_package_name). The execution path needs a
# real macOS/Linuxbrew host, which no spec environment has - the JSON
# parsing and command shapes don't.
describe Krikri::PluginHelpers::Homebrew do
  describe ".valid_package?" do
    it "accepts ordinary formula names" do
      ["git", "node@18", "python@3.11", "openssl+3"].each do |pkg|
        Krikri::PluginHelpers::Homebrew.valid_package?(pkg).should be_true
      end
    end

    it "accepts tap-prefixed cask names" do
      Krikri::PluginHelpers::Homebrew.valid_package?("homebrew/cask/foo").should be_true
    end

    it "rejects shell-hostile names" do
      ["a;rm", "$(x)", "a b"].each do |pkg|
        Krikri::PluginHelpers::Homebrew.valid_package?(pkg).should be_false
      end
    end
  end

  describe ".parse_info" do
    it "marks a formula installed when its installed array is non-empty" do
      json = %({"formulae": [{"name": "git", "full_name": "git", "installed": [{"version": "2.40.0"}], "outdated": false}], "casks": []})
      info = Krikri::PluginHelpers::Homebrew.parse_info(json, ["git"]).should_not be_nil
      info["git"][:installed].should be_true
      info["git"][:outdated].should be_false
    end

    it "marks a formula outdated via the outdated flag" do
      json = %({"formulae": [{"name": "git", "full_name": "git", "installed": [{"version": "2.40.0"}], "outdated": true}], "casks": []})
      info = Krikri::PluginHelpers::Homebrew.parse_info(json, ["git"]).should_not be_nil
      info["git"][:outdated].should be_true
    end

    it "reports absent formulas as not installed" do
      json = %({"formulae": [{"name": "git", "full_name": "git", "installed": [], "outdated": false}], "casks": []})
      info = Krikri::PluginHelpers::Homebrew.parse_info(json, ["git"]).should_not be_nil
      info["git"][:installed].should be_false
    end

    it "matches via aliases like the real _extract_package_name" do
      json = %({"formulae": [{"name": "gnupg", "full_name": "gnupg", "aliases": ["gpg"], "installed": [{"version": "2.4"}], "outdated": false}], "casks": []})
      info = Krikri::PluginHelpers::Homebrew.parse_info(json, ["gpg"]).should_not be_nil
      info["gpg"][:installed].should be_true
    end

    it "matches tap-prefixed cask tokens" do
      json = %({"formulae": [], "casks": [{"token": "firefox", "full_token": "homebrew/cask/firefox", "tap": "homebrew/cask", "installed": [{"version": "1.0"}], "outdated": false}]})
      info = Krikri::PluginHelpers::Homebrew.parse_info(json, ["homebrew/cask/firefox"]).should_not be_nil
      info["homebrew/cask/firefox"][:installed].should be_true
    end

    it "returns nil on unparseable output" do
      Krikri::PluginHelpers::Homebrew.parse_info("not json", ["git"]).should be_nil
    end
  end

  describe ".info_command" do
    it "builds brew info --json=v2 for the requested names" do
      Krikri::PluginHelpers::Homebrew.info_command("/usr/local/bin/brew", ["git", "wget"])
        .should eq("/usr/local/bin/brew info --json=v2 git wget")
    end
  end

  describe ".install_command" do
    it "prefixes install options with -- and appends --formula when forced" do
      Krikri::PluginHelpers::Homebrew.install_command("brew", ["foo"], ["with-baz", "enable-debug"], false, true)
        .should eq("brew install --with-baz --enable-debug foo --formula")
    end

    it "builds --HEAD installs for state=head" do
      Krikri::PluginHelpers::Homebrew.install_command("brew", ["foo"], [] of String, true, false)
        .should eq("brew install foo --HEAD")
    end
  end

  describe ".uninstall_command" do
    it "includes --force like the real module" do
      Krikri::PluginHelpers::Homebrew.uninstall_command("brew", ["foo"], [] of String)
        .should eq("brew uninstall --force foo")
    end
  end

  describe ".update_changed?" do
    it "reports unchanged when brew says Already up-to-date" do
      Krikri::PluginHelpers::Homebrew.update_changed?("Already up-to-date.").should be_false
    end

    it "reports changed on real update output" do
      Krikri::PluginHelpers::Homebrew.update_changed?("Updated 1 tap (v2.40.1).").should be_true
    end
  end

  describe ".link_command" do
    it "builds link and unlink commands" do
      Krikri::PluginHelpers::Homebrew.link_command("brew", ["foo"], [] of String, unlink: false).should eq("brew link foo")
      Krikri::PluginHelpers::Homebrew.link_command("brew", ["foo"], [] of String, unlink: true).should eq("brew unlink foo")
    end
  end
end
