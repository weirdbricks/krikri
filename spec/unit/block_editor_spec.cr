require "../spec_helper"
require "../../src/krikri/plugin_helpers/block_editor"

private alias BlockEditor = Krikri::PluginHelpers::BlockEditor
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

  describe ".apply (append_newline/prepend_newline)" do
    # Semantics live-verified against ansible-core 2.19.4's module
    # source: prepend puts a blank line between the preceding content
    # and the block (skipped at BOF or when the preceding line is
    # already blank); append puts one between the block and what
    # follows it (skipped at EOF or when that line is already blank).
    it "prepends a blank line between the preceding content and a fresh block" do
      lines, _ = BlockEditor.apply(["line1", "line2"], BEGIN_LINE, END_LINE, ["x"], "present", nil, nil, false, true)
      lines.should eq(["line1", "line2", "", BEGIN_LINE, "x", END_LINE])
    end

    it "skips the prepended blank line at BOF" do
      lines, _ = BlockEditor.apply(["line1"], BEGIN_LINE, END_LINE, ["x"], "present", nil, "^line1", false, true)
      lines.should eq([BEGIN_LINE, "x", END_LINE, "line1"])
    end

    it "skips the prepended blank line when the preceding line is already blank" do
      lines, _ = BlockEditor.apply(["line1", ""], BEGIN_LINE, END_LINE, ["x"], "present", nil, nil, false, true)
      lines.should eq(["line1", "", BEGIN_LINE, "x", END_LINE])
    end

    it "appends a blank line between the block and what follows it" do
      lines, _ = BlockEditor.apply(["line1", "line2"], BEGIN_LINE, END_LINE, ["x"], "present", nil, "^line2", true, false)
      lines.should eq(["line1", BEGIN_LINE, "x", END_LINE, "", "line2"])
    end

    it "skips the appended blank line at EOF" do
      lines, _ = BlockEditor.apply(["line1"], BEGIN_LINE, END_LINE, ["x"], "present", nil, nil, true, false)
      lines.should eq(["line1", BEGIN_LINE, "x", END_LINE])
    end

    it "skips the appended blank line when the following line is already blank" do
      lines, _ = BlockEditor.apply(["a", "b", "", "c"], BEGIN_LINE, END_LINE, ["x"], "present", "^b", nil, true, false)
      lines.should eq(["a", "b", BEGIN_LINE, "x", END_LINE, "", "c"])
    end

    it "is idempotent: once the blank lines are in place, the rerun reports unchanged" do
      lines = ["line1", "", BEGIN_LINE, "x", END_LINE, "", "line2"]
      new_lines, changed = BlockEditor.apply(lines, BEGIN_LINE, END_LINE, ["x"], "present", nil, nil, true, true)
      changed.should be_false
      new_lines.should eq(lines)
    end

    it "pads an existing in-place block rewrite the same way" do
      existing = ["line1", BEGIN_LINE, "old", END_LINE, "line2"]
      lines, changed = BlockEditor.apply(existing, BEGIN_LINE, END_LINE, ["new"], "present", nil, nil, true, true)
      changed.should be_true
      lines.should eq(["line1", "", BEGIN_LINE, "new", END_LINE, "", "line2"])
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
