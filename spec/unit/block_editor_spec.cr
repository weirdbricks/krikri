require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/block_editor"

private alias BlockEditor = CrystalPlay::PluginHelpers::BlockEditor
private BEGIN_LINE = "# BEGIN ANSIBLE MANAGED BLOCK"
private END_LINE   = "# END ANSIBLE MANAGED BLOCK"

describe BlockEditor do
  describe ".apply (state: present)" do
    it "inserts a new block at EOF by default" do
      lines, changed = BlockEditor.apply(["line1", "line2"], BEGIN_LINE, END_LINE, ["hello", "world"], "present", nil, nil)
      lines.should eq(["line1", "line2", BEGIN_LINE, "hello", "world", END_LINE])
      changed.should be_true
    end

    it "inserts before a matching insertbefore regexp" do
      lines, changed = BlockEditor.apply(["line1", "line2"], BEGIN_LINE, END_LINE, ["x"], "present", nil, "^line2")
      lines.should eq(["line1", BEGIN_LINE, "x", END_LINE, "line2"])
      changed.should be_true
    end

    it "reports unchanged when the identical block already exists" do
      existing = ["line1", BEGIN_LINE, "x", END_LINE, "line2"]
      lines, changed = BlockEditor.apply(existing, BEGIN_LINE, END_LINE, ["x"], "present", nil, nil)
      lines.should eq(existing)
      changed.should be_false
    end

    it "rewrites an existing block's contents in place, without moving it" do
      existing = ["line1", BEGIN_LINE, "old", END_LINE, "line2"]
      lines, changed = BlockEditor.apply(existing, BEGIN_LINE, END_LINE, ["new1", "new2"], "present", nil, nil)
      lines.should eq(["line1", BEGIN_LINE, "new1", "new2", END_LINE, "line2"])
      changed.should be_true
    end

    it "treats a begin marker with no matching end as not found and inserts fresh" do
      lines, changed = BlockEditor.apply([BEGIN_LINE, "stray"], BEGIN_LINE, END_LINE, ["x"], "present", nil, nil)
      lines.should eq([BEGIN_LINE, "stray", BEGIN_LINE, "x", END_LINE])
      changed.should be_true
    end
  end

  describe ".apply (state: absent)" do
    it "removes an existing block entirely" do
      lines, changed = BlockEditor.apply(["line1", BEGIN_LINE, "x", END_LINE, "line2"], BEGIN_LINE, END_LINE, [] of String, "absent", nil, nil)
      lines.should eq(["line1", "line2"])
      changed.should be_true
    end

    it "reports unchanged when no block is present" do
      lines, changed = BlockEditor.apply(["line1", "line2"], BEGIN_LINE, END_LINE, [] of String, "absent", nil, nil)
      lines.should eq(["line1", "line2"])
      changed.should be_false
    end
  end
end
