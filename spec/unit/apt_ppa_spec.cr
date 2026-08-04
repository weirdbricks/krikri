require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/apt_ppa"
require "../../src/crystal_play/plugin_helpers/apt_repository_line"

describe CrystalPlay::PluginHelpers::AptPpa do
  describe ".parse" do
    it "parses owner/name" do
      info = CrystalPlay::PluginHelpers::AptPpa.parse("ppa:nginx/stable")
      info.should_not be_nil
      info.try(&.owner).should eq("nginx")
      info.try(&.name).should eq("stable")
    end

    it "defaults name to 'ppa' when omitted" do
      info = CrystalPlay::PluginHelpers::AptPpa.parse("ppa:nginx")
      info.should_not be_nil
      info.try(&.owner).should eq("nginx")
      info.try(&.name).should eq("ppa")
    end

    it "returns nil for a non-ppa: repo string" do
      CrystalPlay::PluginHelpers::AptPpa.parse("deb http://example.com jammy main").should be_nil
    end

    it "returns nil when the owner is missing" do
      CrystalPlay::PluginHelpers::AptPpa.parse("ppa:").should be_nil
      CrystalPlay::PluginHelpers::AptPpa.parse("ppa:/stable").should be_nil
    end
  end

  describe ".expand_line" do
    it "builds the exact deb line shape real Ansible's own _expand_ppa produces" do
      info = CrystalPlay::PluginHelpers::AptPpa::Info.new("nginx", "stable")
      CrystalPlay::PluginHelpers::AptPpa.expand_line(info, "jammy").should eq(
        "deb https://ppa.launchpadcontent.net/nginx/stable/ubuntu jammy main"
      )
    end
  end

  describe ".api_url" do
    it "builds the Launchpad API URL" do
      info = CrystalPlay::PluginHelpers::AptPpa::Info.new("nginx", "stable")
      CrystalPlay::PluginHelpers::AptPpa.api_url(info).should eq("https://api.launchpad.net/1.0/~nginx/+archive/stable")
    end
  end

  describe ".filename_source" do
    it "matches real Ansible's own pre-expansion _suggest_filename input" do
      info = CrystalPlay::PluginHelpers::AptPpa::Info.new("nginx", "stable")
      CrystalPlay::PluginHelpers::AptPpa.filename_source(info, "jammy").should eq("ppa:nginx/stable_jammy")
    end

    it "produces 'ppa_nginx_stable_jammy' once run through AptRepositoryLine.suggested_filename" do
      info = CrystalPlay::PluginHelpers::AptPpa::Info.new("nginx", "stable")
      source = CrystalPlay::PluginHelpers::AptPpa.filename_source(info, "jammy")
      CrystalPlay::PluginHelpers::AptRepositoryLine.suggested_filename(source).should eq("ppa_nginx_stable_jammy")
    end
  end

  describe ".keyfile_name" do
    it "matches real Ansible's own os.path.basename(source)-derived keyfile name" do
      info = CrystalPlay::PluginHelpers::AptPpa::Info.new("nginx", "stable")
      CrystalPlay::PluginHelpers::AptPpa.keyfile_name(info, "jammy").should eq("ubuntu-jammy-main-nginx-stable.gpg")
    end
  end
end
