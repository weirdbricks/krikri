require "../minitest_helper"
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
        Krikri::PluginHelpers::Homebrew.valid_package?(pkg).must_equal(true)
      end
    end

    it "accepts tap-prefixed cask names" do
      Krikri::PluginHelpers::Homebrew.valid_package?("homebrew/cask/foo").must_equal(true)
    end

    it "rejects shell-hostile names" do
      ["a;rm", "$(x)", "a b"].each do |pkg|
        Krikri::PluginHelpers::Homebrew.valid_package?(pkg).must_equal(false)
      end
    end
  end

  describe ".parse_info" do
    it "marks a formula installed when its installed array is non-empty" do
      json = %({"formulae": [{"name": "git", "full_name": "git", "installed": [{"version": "2.40.0"}], "outdated": false}], "casks": []})
      info = Krikri::PluginHelpers::Homebrew.parse_info(json, ["git"]).not_nil!
      info.wont_be_nil
      info["git"][:installed].must_equal(true)
      info["git"][:outdated].must_equal(false)
    end

    it "marks a formula outdated via the outdated flag" do
      json = %({"formulae": [{"name": "git", "full_name": "git", "installed": [{"version": "2.40.0"}], "outdated": true}], "casks": []})
      info = Krikri::PluginHelpers::Homebrew.parse_info(json, ["git"]).not_nil!
      info.wont_be_nil
      info["git"][:outdated].must_equal(true)
    end

    it "reports absent formulas as not installed" do
      json = %({"formulae": [{"name": "git", "full_name": "git", "installed": [], "outdated": false}], "casks": []})
      info = Krikri::PluginHelpers::Homebrew.parse_info(json, ["git"]).not_nil!
      info.wont_be_nil
      info["git"][:installed].must_equal(false)
    end

    it "matches via aliases like the real _extract_package_name" do
      json = %({"formulae": [{"name": "gnupg", "full_name": "gnupg", "aliases": ["gpg"], "installed": [{"version": "2.4"}], "outdated": false}], "casks": []})
      info = Krikri::PluginHelpers::Homebrew.parse_info(json, ["gpg"]).not_nil!
      info.wont_be_nil
      info["gpg"][:installed].must_equal(true)
    end

    it "matches tap-prefixed cask tokens" do
      json = %({"formulae": [], "casks": [{"token": "firefox", "full_token": "homebrew/cask/firefox", "tap": "homebrew/cask", "installed": [{"version": "1.0"}], "outdated": false}]})
      info = Krikri::PluginHelpers::Homebrew.parse_info(json, ["homebrew/cask/firefox"]).not_nil!
      info.wont_be_nil
      info["homebrew/cask/firefox"][:installed].must_equal(true)
    end

    it "returns nil on unparseable output" do
      Krikri::PluginHelpers::Homebrew.parse_info("not json", ["git"]).must_be_nil
    end
  end

  describe ".info_command" do
    it "builds brew info --json=v2 for the requested names" do
      Krikri::PluginHelpers::Homebrew.info_command("/usr/local/bin/brew", ["git", "wget"])
        .must_equal("/usr/local/bin/brew info --json=v2 git wget")
    end
  end

  describe ".install_command" do
    it "prefixes install options with -- and appends --formula when forced" do
      Krikri::PluginHelpers::Homebrew.install_command("brew", ["foo"], ["with-baz", "enable-debug"], false, true)
        .must_equal("brew install --with-baz --enable-debug foo --formula")
    end

    it "builds --HEAD installs for state=head" do
      Krikri::PluginHelpers::Homebrew.install_command("brew", ["foo"], [] of String, true, false)
        .must_equal("brew install foo --HEAD")
    end
  end

  describe ".uninstall_command" do
    it "includes --force like the real module" do
      Krikri::PluginHelpers::Homebrew.uninstall_command("brew", ["foo"], [] of String)
        .must_equal("brew uninstall --force foo")
    end
  end

  describe ".update_changed?" do
    it "reports unchanged when brew says Already up-to-date" do
      Krikri::PluginHelpers::Homebrew.update_changed?("Already up-to-date.").must_equal(false)
    end

    it "reports changed on real update output" do
      Krikri::PluginHelpers::Homebrew.update_changed?("Updated 1 tap (v2.40.1).").must_equal(true)
    end
  end

  describe ".link_command" do
    it "builds link and unlink commands" do
      Krikri::PluginHelpers::Homebrew.link_command("brew", ["foo"], [] of String, unlink: false).must_equal("brew link foo")
      Krikri::PluginHelpers::Homebrew.link_command("brew", ["foo"], [] of String, unlink: true).must_equal("brew unlink foo")
    end
  end

  # Command-builder quoting: real Ansible builds an argv list where a
  # hostile token is inert, so the shell-string equivalent must keep a
  # metacharacter-bearing element one literal argument. Well-formed
  # values stay byte-identical (quote_arg leaves safe tokens bare).
  describe "command-builder quoting" do
    it "quotes a brew_path carrying shell metacharacters" do
      Krikri::PluginHelpers::Homebrew.info_command("/opt/bin; touch /tmp/pwned", ["git"])
        .must_equal("'/opt/bin; touch /tmp/pwned' info --json=v2 git")
      Krikri::PluginHelpers::Homebrew.upgrade_command("/opt/bin; touch /tmp/pwned", [] of String, [] of String)
        .must_equal("'/opt/bin; touch /tmp/pwned' upgrade")
    end

    it "quotes hostile option and package tokens while leaving well-formed ones bare" do
      Krikri::PluginHelpers::Homebrew.install_command("brew", ["git; touch /tmp/pwned"], ["with-baz"], false, false)
        .must_equal("brew install --with-baz 'git; touch /tmp/pwned'")
      Krikri::PluginHelpers::Homebrew.upgrade_command("brew", ["git"], ["ignore-pinned; touch /tmp/pwned"])
        .must_equal("brew upgrade '--ignore-pinned; touch /tmp/pwned' git")
    end
  end
end
