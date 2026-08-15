require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/gem_command"

# Real bugs found via a proactive scope-cut audit: repository:/
# include_dependencies:/norc: were entirely unimplemented. Verified
# against real community.general gem.py's own install/uninstall/
# common_opts source directly (flag order included), not assumed from
# ansible-doc.
describe CrystalPlay::PluginHelpers::GemCommand do
  describe ".install_command" do
    it "adds --source for repository:" do
      cmd = CrystalPlay::PluginHelpers::GemCommand.install_command(
        "gem", "rake", nil, true, nil, "https://rubygems.example.com", true, false
      )
      cmd.should eq(%(gem install --source "https://rubygems.example.com" --user-install --no-document rake))
    end

    it "adds --ignore-dependencies only when include_dependencies: is false (default true adds nothing)" do
      with_deps = CrystalPlay::PluginHelpers::GemCommand.install_command("gem", "rake", nil, true, nil, nil, true, false)
      without_deps = CrystalPlay::PluginHelpers::GemCommand.install_command("gem", "rake", nil, true, nil, nil, false, false)

      with_deps.should eq(%(gem install --user-install --no-document rake))
      without_deps.should eq(%(gem install --ignore-dependencies --user-install --no-document rake))
    end

    it "adds --norc when requested" do
      cmd = CrystalPlay::PluginHelpers::GemCommand.install_command("gem", "rake", nil, true, nil, nil, true, true)
      cmd.should eq(%(gem install --norc --user-install --no-document rake))
    end

    it "matches real gem.py's own flag order: install, [--norc], [-v], [--source], [--ignore-dependencies], [user-install], [--bindir], --no-document, name" do
      cmd = CrystalPlay::PluginHelpers::GemCommand.install_command(
        "gem", "rake", "13.0.6", false, "/opt/bin", "https://example.com", false, true
      )
      cmd.should eq(%(gem install --norc -v "13.0.6" --source "https://example.com" --ignore-dependencies --no-user-install --bindir "/opt/bin" --no-document rake))
    end
  end

  describe ".uninstall_command" do
    it "builds the base uninstall command" do
      CrystalPlay::PluginHelpers::GemCommand.uninstall_command("gem", "rake", nil, false).should eq(
        "gem uninstall rake --executables --force"
      )
    end

    it "adds --norc and -v" do
      CrystalPlay::PluginHelpers::GemCommand.uninstall_command("gem", "rake", "13.0.6", true).should eq(
        %(gem uninstall --norc rake --executables --force -v "13.0.6")
      )
    end
  end
end
