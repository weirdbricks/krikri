require "../spec_helper"
require "../../src/krikri/plugin_helpers/sefcontext_commands"

# Unit-tests the semanage output parsing / command construction against
# real community.general.sefcontext's own behavior (read from its
# source) - the plugin's execution paths need a real SELinux policy
# store, the parsing and argv shapes don't.
describe Krikri::PluginHelpers::SefcontextCommands do
  describe ".parse_listing" do
    it "parses target/ftype/context columns past the header" do
      listing = "SELinux fcontext       Type            Context
/                      all files       system_u:object_r:root_t:s0
/srv/git_repos(/.*)?   all files       system_u:object_r:httpd_sys_rw_content_t:s0
/var/run               directory       system_u:object_r:var_run_t:s0
"
      records = Krikri::PluginHelpers::SefcontextCommands.parse_listing(listing)
      records.size.should eq(3)
      records[0].target.should eq("/")
      records[0].ftype_str.should eq("all files")
      records[1].target.should eq("/srv/git_repos(/.*)?")
      records[1].context.should eq("system_u:object_r:httpd_sys_rw_content_t:s0")
      records[2].ftype_str.should eq("directory")
    end

    it "keeps the <<None>> context verbatim" do
      listing = "/x   all files   <<None>>\n"
      records = Krikri::PluginHelpers::SefcontextCommands.parse_listing(listing)
      records[0].context.should eq("<<None>>")
    end
  end

  describe ".parse_equivalences" do
    it "parses target = substitute lines" do
      listing2 = "/srv/containers = /var/lib/containers\n/other = /elsewhere\n"
      result = Krikri::PluginHelpers::SefcontextCommands.parse_equivalences(listing2)
      result["/srv/containers"].should eq("/var/lib/containers")
      result["/other"].should eq("/elsewhere")
    end
  end

  describe ".add_command / .modify_command" do
    it "builds an add with defaults for ftype a (no -f flag)" do
      cmd = Krikri::PluginHelpers::SefcontextCommands.add_command("/srv/git_repos(/.*)?", "httpd_sys_rw_content_t", "a", "system_u", "s0")
      cmd.should eq(["semanage", "fcontext", "-a", "-t", "httpd_sys_rw_content_t", "-s", "system_u", "-r", "s0",
                     "/srv/git_repos(/.*)?"])
    end

    it "maps ftype f to the -- flag" do
      cmd = Krikri::PluginHelpers::SefcontextCommands.modify_command("/x", "type_t", "f", "system_u", "s0")
      cmd.should eq(["semanage", "fcontext", "-m", "-t", "type_t", "-s", "system_u", "-r", "s0", "-f", "--", "/x"])
    end
  end

  describe ".delete_command" do
    it "carries the ftype flag for non-all-file deletes" do
      Krikri::PluginHelpers::SefcontextCommands.delete_command("/x", "d")
        .should eq(["semanage", "fcontext", "-d", "-f", "d", "/x"])
      Krikri::PluginHelpers::SefcontextCommands.delete_command("/x", "a")
        .should eq(["semanage", "fcontext", "-d", "/x"])
    end
  end

  describe ".add_equal_command" do
    it "uses -a for a new equivalence and -m to rewrite one" do
      Krikri::PluginHelpers::SefcontextCommands.add_equal_command("/srv/containers", "/var/lib/containers", false)
        .should eq(["semanage", "fcontext", "-a", "-e", "/var/lib/containers", "/srv/containers"])
      Krikri::PluginHelpers::SefcontextCommands.add_equal_command("/srv/containers", "/var/lib/containers", true)
        .should eq(["semanage", "fcontext", "-m", "-e", "/var/lib/containers", "/srv/containers"])
    end
  end
end
