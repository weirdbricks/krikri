require "../minitest_helper"
require "../../src/krikri/plugin_helpers/gem_command"

# Real bugs found via a proactive scope-cut audit: repository:/
# include_dependencies:/norc: were entirely unimplemented. Verified
# against real community.general gem.py's own install/uninstall/
# common_opts source directly (flag order included), not assumed from
# ansible-doc.
describe Krikri::PluginHelpers::GemCommand do
  describe ".install_command" do
    it "adds --source for repository:" do
      cmd = Krikri::PluginHelpers::GemCommand.install_command(
        "gem", "rake", nil, true, nil, "https://rubygems.example.com", true, false
      )
      cmd.must_equal(%(gem install --source "https://rubygems.example.com" --user-install --no-document rake))
    end

    it "adds --ignore-dependencies only when include_dependencies: is false (default true adds nothing)" do
      with_deps = Krikri::PluginHelpers::GemCommand.install_command("gem", "rake", nil, true, nil, nil, true, false)
      without_deps = Krikri::PluginHelpers::GemCommand.install_command("gem", "rake", nil, true, nil, nil, false, false)

      with_deps.must_equal(%(gem install --user-install --no-document rake))
      without_deps.must_equal(%(gem install --ignore-dependencies --user-install --no-document rake))
    end

    it "adds --norc when requested" do
      cmd = Krikri::PluginHelpers::GemCommand.install_command("gem", "rake", nil, true, nil, nil, true, true)
      cmd.must_equal(%(gem install --norc --user-install --no-document rake))
    end

    it "matches Ansible's gem module's own flag order: install, [--norc], [--version], [--source], [--ignore-dependencies], [user-install], [--bindir], --no-document, name" do
      cmd = Krikri::PluginHelpers::GemCommand.install_command(
        "gem", "rake", "13.0.6", false, "/opt/bin", "https://example.com", false, true
      )
      cmd.must_equal(%(gem install --norc --version 13.0.6 --source "https://example.com" --ignore-dependencies --no-user-install --bindir "/opt/bin" --no-document rake))
    end

    # Issue #1345: real's install args_order has no `name` at all - its
    # positional is gem_source (defaulted to name), so a gem_source path
    # replaces the gem name. build_flags follow `--`; include_doc true
    # omits --no-document; pre_release/env_shebang/force add their flags
    # in real's order. Live-verified argv (ansible-playbook 2.21.6):
    # `gem install --norc --user-install /tmp/kpg-work/sub -- eifxzc`.
    it "adds --pre/--env-shebang/--force and passes build_flags after -- in real's order" do
      cmd = Krikri::PluginHelpers::GemCommand.install_command(
        "gem", "/tmp/kpg-work/sub", nil, true, nil, nil, true, true,
        pre_release: true, include_doc: false, env_shebang: true,
        build_flags: "eifxzc", force: true,
      )
      cmd.must_equal(%(gem install --norc --user-install --pre --no-document --env-shebang /tmp/kpg-work/sub -- eifxzc --force))
    end

    it "omits --no-document when include_doc is true" do
      cmd = Krikri::PluginHelpers::GemCommand.install_command(
        "gem", "crtibd", nil, true, nil, nil, true, true, include_doc: true
      )
      cmd.must_equal(%(gem install --norc --user-install crtibd))
    end

    # Real hands gem_source to run_command as a single argv element, so a
    # path with a space must not word-split; shlex.join (real's cmd
    # display) renders the same path single-quoted.
    it "keeps a gem_source path with a space as one argv element" do
      cmd = Krikri::PluginHelpers::GemCommand.install_command(
        "gem", "/tmp/a b/sub.gem", nil, true, nil, nil, true, false
      )
      cmd.must_equal(%(gem install --user-install --no-document '/tmp/a b/sub.gem'))
    end
  end

  describe ".uninstall_command" do
    # Real uninstall's CmdRunner args_order: subcmd, norc, install_dir,
    # bindir, version (--version X, or --all without), --executable
    # (always), force (only when the module's force param is set), name.
    # Shim-logged against real ansible-playbook 2.17 + latest
    # community.general (the argv real fed `gem`).
    it "builds the base uninstall command" do
      Krikri::PluginHelpers::GemCommand.uninstall_command("gem", "rake", nil, false).must_equal(
        "gem uninstall --all --executable rake"
      )
    end

    it "adds --norc and --version" do
      Krikri::PluginHelpers::GemCommand.uninstall_command("gem", "rake", "13.0.6", true).must_equal(
        "gem uninstall --norc --version 13.0.6 --executable rake"
      )
    end
  end

  describe ".parse_list_versions" do
    it "parses plain local list output" do
      Krikri::PluginHelpers::GemCommand.parse_list_versions(
        "hashie (5.1.0)\nminitar (1.1.0)\n"
      ).must_equal(["5.1.0", "1.1.0"])
    end

    it "handles the 'default:' prefix and multiple versions on one line" do
      Krikri::PluginHelpers::GemCommand.parse_list_versions(
        "rake (default: 13.0.6, 12.3.3)\n"
      ).must_equal(["13.0.6", "12.3.3"])
    end

    it "strips platform suffixes (only the first token of a version is kept)" do
      Krikri::PluginHelpers::GemCommand.parse_list_versions(
        "nokogiri (1.16.0 x86_64-linux, 1.16.0 aarch64-linux)\n"
      ).must_equal(["1.16.0", "1.16.0"])
    end

    it "ignores non-matching lines" do
      Krikri::PluginHelpers::GemCommand.parse_list_versions(
        "*** LOCAL GEMS ***\n\nhashie (5.1.0)\n"
      ).must_equal(["5.1.0"])
    end

    it "returns an empty list for a gem with no output" do
      Krikri::PluginHelpers::GemCommand.parse_list_versions("").must_equal([] of String)
    end
  end
end
