require "../spec_helper"
require "../../src/krikri/plugin_helpers/easy_install"

# Unit-tests the easy_install logic against real community.general
# .easy_install's own behavior (_get_easy_install, _is_package_installed,
# the executable_arguments flow). Execution needs a real host with
# easy_install/virtualenv - the command shapes and probe semantics don't.
describe Krikri::PluginHelpers::EasyInstall do
  describe ".resolve_executable" do
    it "uses an absolute executable path verbatim" do
      Krikri::PluginHelpers::EasyInstall.resolve_executable("/usr/bin/easy_install-3.3", "/venv")
        .should eq("/usr/bin/easy_install-3.3")
    end

    it "prefers the virtualenv bin dir for a basename executable" do
      Krikri::PluginHelpers::EasyInstall.resolve_executable("easy_install-3.3", "/webapps/myapp/venv")
        .should eq("/webapps/myapp/venv/bin/easy_install-3.3")
    end

    it "falls back to the plain executable name without a virtualenv" do
      Krikri::PluginHelpers::EasyInstall.resolve_executable(nil, nil).should eq("easy_install")
      Krikri::PluginHelpers::EasyInstall.resolve_executable("easy_install", nil).should eq("easy_install")
    end

    it "resolves the default executable inside the virtualenv" do
      Krikri::PluginHelpers::EasyInstall.resolve_executable(nil, "/opt/myenv")
        .should eq("/opt/myenv/bin/easy_install")
    end
  end

  describe ".state_arguments" do
    it "adds --upgrade for state=latest" do
      Krikri::PluginHelpers::EasyInstall.state_arguments("latest").should eq("--upgrade")
    end

    it "adds nothing for state=present" do
      Krikri::PluginHelpers::EasyInstall.state_arguments("present").should eq("")
    end
  end

  describe ".probe_command" do
    it "appends --dry-run before the package name" do
      Krikri::PluginHelpers::EasyInstall.probe_command("easy_install", ["--upgrade"], "pip")
        .should eq("easy_install --upgrade --dry-run pip")
    end

    it "omits empty argument slots" do
      Krikri::PluginHelpers::EasyInstall.probe_command("easy_install", [""], "bottle")
        .should eq("easy_install --dry-run bottle")
    end
  end

  describe ".install_command" do
    it "builds the real install invocation" do
      Krikri::PluginHelpers::EasyInstall.install_command("easy_install", [""], "pip")
        .should eq("easy_install pip")
      Krikri::PluginHelpers::EasyInstall.install_command("easy_install", ["--upgrade"], "pip")
        .should eq("easy_install --upgrade pip")
    end
  end

  describe ".installed?" do
    it "reports not installed when the dry-run says Downloading" do
      Krikri::PluginHelpers::EasyInstall.installed?("Downloading pip-24.0.tar.gz").should be_false
    end

    it "reports installed when the dry-run finds nothing to download" do
      Krikri::PluginHelpers::EasyInstall.installed?("Best match: pip 24.0").should be_true
    end
  end

  describe ".venv_create_command" do
    it "adds --system-site-packages when site_packages is on" do
      Krikri::PluginHelpers::EasyInstall.venv_create_command("virtualenv", "/venv", true)
        .should eq("virtualenv /venv --system-site-packages")
    end

    it "creates a plain virtualenv otherwise" do
      Krikri::PluginHelpers::EasyInstall.venv_create_command("pyvenv", "/opt/myenv", false)
        .should eq("pyvenv /opt/myenv")
    end
  end
end
