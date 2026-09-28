require "../minitest_helper"
require "../../src/krikri/plugin_helpers/easy_install"

# Unit-tests the easy_install logic against real community.general
# .easy_install's own behavior (_get_easy_install, _is_package_installed,
# the executable_arguments flow). Execution needs a real host with
# easy_install/virtualenv - the command shapes and probe semantics don't.
describe Krikri::PluginHelpers::EasyInstall do
  describe ".resolve_executable" do
    it "uses an absolute executable path verbatim" do
      Krikri::PluginHelpers::EasyInstall.resolve_executable("/usr/bin/easy_install-3.3", "/venv")
        .must_equal("/usr/bin/easy_install-3.3")
    end

    it "prefers the virtualenv bin dir for a basename executable" do
      Krikri::PluginHelpers::EasyInstall.resolve_executable("easy_install-3.3", "/webapps/myapp/venv")
        .must_equal("/webapps/myapp/venv/bin/easy_install-3.3")
    end

    it "falls back to the plain executable name without a virtualenv" do
      Krikri::PluginHelpers::EasyInstall.resolve_executable(nil, nil).must_equal("easy_install")
      Krikri::PluginHelpers::EasyInstall.resolve_executable("easy_install", nil).must_equal("easy_install")
    end

    it "resolves the default executable inside the virtualenv" do
      Krikri::PluginHelpers::EasyInstall.resolve_executable(nil, "/opt/myenv")
        .must_equal("/opt/myenv/bin/easy_install")
    end
  end

  describe ".state_arguments" do
    it "adds --upgrade for state=latest" do
      Krikri::PluginHelpers::EasyInstall.state_arguments("latest").must_equal("--upgrade")
    end

    it "adds nothing for state=present" do
      Krikri::PluginHelpers::EasyInstall.state_arguments("present").must_equal("")
    end
  end

  describe ".probe_command" do
    it "appends --dry-run before the package name" do
      Krikri::PluginHelpers::EasyInstall.probe_command("easy_install", ["--upgrade"], "pip")
        .must_equal("easy_install --upgrade --dry-run pip")
    end

    it "omits empty argument slots" do
      Krikri::PluginHelpers::EasyInstall.probe_command("easy_install", [""], "bottle")
        .must_equal("easy_install --dry-run bottle")
    end
  end

  describe ".install_command" do
    it "builds the real install invocation" do
      Krikri::PluginHelpers::EasyInstall.install_command("easy_install", [""], "pip")
        .must_equal("easy_install pip")
      Krikri::PluginHelpers::EasyInstall.install_command("easy_install", ["--upgrade"], "pip")
        .must_equal("easy_install --upgrade pip")
    end
  end

  describe ".installed?" do
    it "reports not installed when the dry-run says Downloading" do
      Krikri::PluginHelpers::EasyInstall.installed?("Downloading pip-24.0.tar.gz").must_equal(false)
    end

    it "reports installed when the dry-run finds nothing to download" do
      Krikri::PluginHelpers::EasyInstall.installed?("Best match: pip 24.0").must_equal(true)
    end
  end

  describe ".venv_create_command" do
    it "adds --system-site-packages when site_packages is on" do
      Krikri::PluginHelpers::EasyInstall.venv_create_command("virtualenv", "/venv", true)
        .must_equal("virtualenv /venv --system-site-packages")
    end

    it "creates a plain virtualenv otherwise" do
      Krikri::PluginHelpers::EasyInstall.venv_create_command("pyvenv", "/opt/myenv", false)
        .must_equal("pyvenv /opt/myenv")
    end
  end
end
