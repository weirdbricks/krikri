require "../minitest_helper"
require "../../src/krikri/plugin_helpers/apt_ppa"
require "../../src/krikri/plugin_helpers/apt_repository_line"

describe Krikri::PluginHelpers::AptPpa do
  describe ".parse" do
    it "parses owner/name" do
      info = Krikri::PluginHelpers::AptPpa.parse("ppa:nginx/stable")
      info.wont_be_nil
      info.try(&.owner).must_equal("nginx")
      info.try(&.name).must_equal("stable")
    end

    it "defaults name to 'ppa' when omitted" do
      info = Krikri::PluginHelpers::AptPpa.parse("ppa:nginx")
      info.wont_be_nil
      info.try(&.owner).must_equal("nginx")
      info.try(&.name).must_equal("ppa")
    end

    it "returns nil for a non-ppa: repo string" do
      Krikri::PluginHelpers::AptPpa.parse("deb http://example.com jammy main").must_be_nil
    end

    it "returns nil when the owner is missing" do
      Krikri::PluginHelpers::AptPpa.parse("ppa:").must_be_nil
      Krikri::PluginHelpers::AptPpa.parse("ppa:/stable").must_be_nil
    end
  end

  describe ".expand_line" do
    it "builds the exact deb line shape real Ansible's own _expand_ppa produces" do
      info = Krikri::PluginHelpers::AptPpa::Info.new("nginx", "stable")
      Krikri::PluginHelpers::AptPpa.expand_line(info, "jammy").must_equal(
        "deb https://ppa.launchpadcontent.net/nginx/stable/ubuntu jammy main"
      )
    end
  end

  describe ".api_url" do
    it "builds the Launchpad API URL" do
      info = Krikri::PluginHelpers::AptPpa::Info.new("nginx", "stable")
      Krikri::PluginHelpers::AptPpa.api_url(info).must_equal("https://api.launchpad.net/1.0/~nginx/+archive/stable")
    end
  end

  describe ".filename_source" do
    it "matches real Ansible's own pre-expansion _suggest_filename input" do
      info = Krikri::PluginHelpers::AptPpa::Info.new("nginx", "stable")
      Krikri::PluginHelpers::AptPpa.filename_source(info, "jammy").must_equal("ppa:nginx/stable_jammy")
    end

    it "produces 'ppa_nginx_stable_jammy' once run through AptRepositoryLine.suggested_filename" do
      info = Krikri::PluginHelpers::AptPpa::Info.new("nginx", "stable")
      source = Krikri::PluginHelpers::AptPpa.filename_source(info, "jammy")
      Krikri::PluginHelpers::AptRepositoryLine.suggested_filename(source).must_equal("ppa_nginx_stable_jammy")
    end
  end

  describe ".keyfile_name" do
    it "matches real Ansible's own os.path.basename(source)-derived keyfile name" do
      info = Krikri::PluginHelpers::AptPpa::Info.new("nginx", "stable")
      Krikri::PluginHelpers::AptPpa.keyfile_name(info, "jammy").must_equal("ubuntu-jammy-main-nginx-stable.gpg")
    end
  end
end
