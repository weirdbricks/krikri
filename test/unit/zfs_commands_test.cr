require "../minitest_helper"
require "json"
require "../../src/krikri/plugin_helpers/zfs_commands"

# Unit-tests the command construction/parsing against real
# community.general.zfs's own Zfs class (read from its source) - the
# plugin's execution paths need a real ZFS pool, the argv shapes and
# the `zfs get` output parsing don't.
describe Krikri::PluginHelpers::ZfsCommands do
  describe ".normalize_value" do
    it "maps Python bools to on/off like the real module" do
      Krikri::PluginHelpers::ZfsCommands.normalize_value(JSON.parse("true")).must_equal("on")
      Krikri::PluginHelpers::ZfsCommands.normalize_value(JSON.parse("false")).must_equal("off")
    end

    it "passes strings through" do
      Krikri::PluginHelpers::ZfsCommands.normalize_value(JSON.parse("\"lz4\"")).must_equal("lz4")
    end
  end

  describe ".create_command" do
    it "builds a plain filesystem create with -p and -o pairs" do
      cmd = Krikri::PluginHelpers::ZfsCommands.create_command("rpool/myfs", {"setuid" => "off"}, nil)
      cmd.must_equal(["zfs", "create", "-p", "-o", "setuid=off", "rpool/myfs"])
    end

    it "special-cases volsize to -V and volblocksize to -b" do
      cmd = Krikri::PluginHelpers::ZfsCommands.create_command("rpool/myvol", {"volsize" => "10M", "volblocksize" => "8K"}, nil)
      cmd.must_equal(["zfs", "create", "-p", "-V", "10M", "-b", "8K", "rpool/myvol"])
    end

    it "snapshots when the name has an @" do
      cmd = Krikri::PluginHelpers::ZfsCommands.create_command("rpool/myfs@snap", {} of String => String, nil)
      cmd.must_equal(["zfs", "snapshot", "rpool/myfs@snap"])
    end

    it "clones from origin" do
      cmd = Krikri::PluginHelpers::ZfsCommands.create_command("rpool/cloned_fs", {} of String => String, "rpool/myfs@snap")
      cmd.must_equal(["zfs", "clone", "-p", "rpool/myfs@snap", "rpool/cloned_fs"])
    end

    it "rejects origin on a snapshot name" do
      Krikri::PluginHelpers::ZfsCommands.create_command("rpool/myfs@snap", {} of String => String, "rpool/x@y").must_be_nil
    end
  end

  describe ".destroy_command" do
    it "destroys recursively" do
      Krikri::PluginHelpers::ZfsCommands.destroy_command("rpool/myfs").must_equal(["zfs", "destroy", "-R", "rpool/myfs"])
    end
  end

  describe ".set_property_command" do
    it "sets a single property" do
      Krikri::PluginHelpers::ZfsCommands.set_property_command("rpool/myfs", "compression", "lz4")
        .must_equal(["zfs", "set", "compression=lz4", "rpool/myfs"])
    end
  end

  describe ".parse_list_properties" do
    it "keeps only local/received/- sourced properties" do
      text = "compression\tlocal\nmountpoint\t/\nvolblocksize\t-\nquota\tdefault\n"
      Krikri::PluginHelpers::ZfsCommands.parse_list_properties(text).must_equal(["compression", "volblocksize"])
    end
  end
end
