require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/line_editor"

private alias LineEditor = CrystalPlay::PluginHelpers::LineEditor

describe LineEditor do
  describe ".remove_matching" do
    it "removes an exact match and reports changed" do
      lines, changed = LineEditor.remove_matching(["keep me", "remove me", ""], "remove me", nil)
      lines.should eq(["keep me", ""])
      changed.should be_true
    end

    it "removes every line matching a regexp" do
      lines, changed = LineEditor.remove_matching(["a=1", "b=2", "a=3"], nil, "^a=")
      lines.should eq(["b=2"])
      changed.should be_true
    end

    it "reports unchanged when nothing matches" do
      lines, changed = LineEditor.remove_matching(["keep me"], "not here", nil)
      lines.should eq(["keep me"])
      changed.should be_false
    end
  end

  describe ".ensure_present" do
    it "reports unchanged when the exact line already exists" do
      lines, changed = LineEditor.ensure_present(["hello world"], "hello world", nil, false, nil, nil)
      lines.should eq(["hello world"])
      changed.should be_false
    end

    it "appends the line when it is missing and no insertion point is given" do
      lines, changed = LineEditor.ensure_present(["existing"], "new line", nil, false, nil, nil)
      lines.should eq(["existing", "new line"])
      changed.should be_true
    end

    it "replaces the line matched by regexp" do
      lines, changed = LineEditor.ensure_present(["port=22"], "port=2222", "^port=", false, nil, nil)
      lines.should eq(["port=2222"])
      changed.should be_true
    end

    it "leaves the file untouched when the regexp match already equals the desired line" do
      lines, changed = LineEditor.ensure_present(["port=22"], "port=22", "^port=", false, nil, nil)
      lines.should eq(["port=22"])
      changed.should be_false
    end

    it "substitutes backreferences instead of replacing the whole line" do
      lines, changed = LineEditor.ensure_present(["name=alice"], "name=\\1-updated", "name=(\\w+)", true, nil, nil)
      lines.should eq(["name=alice-updated"])
      changed.should be_true
    end

    it "inserts after a matching insertafter pattern" do
      lines, changed = LineEditor.ensure_present(["[section]", "a=1"], "b=2", nil, false, "^a=", nil)
      lines.should eq(["[section]", "a=1", "b=2"])
      changed.should be_true
    end

    it "inserts at EOF when insertafter is EOF" do
      lines, changed = LineEditor.ensure_present(["a", "b"], "c", nil, false, "EOF", nil)
      lines.should eq(["a", "b", "c"])
      changed.should be_true
    end

    it "inserts before a matching insertbefore pattern" do
      lines, changed = LineEditor.ensure_present(["a=1", "[section]"], "b=2", nil, false, nil, "^\\[")
      lines.should eq(["a=1", "b=2", "[section]"])
      changed.should be_true
    end

    it "inserts at BOF when insertbefore is BOF" do
      lines, changed = LineEditor.ensure_present(["a", "b"], "z", nil, false, nil, "BOF")
      lines.should eq(["z", "a", "b"])
      changed.should be_true
    end

    it "falls back to appending at the end when the insertafter pattern is not found" do
      lines, changed = LineEditor.ensure_present(["x"], "y", nil, false, "^nomatch", nil)
      lines.should eq(["x", "y"])
      changed.should be_true
    end
  end

  describe ".matches_regexp?" do
    it "returns false instead of raising for an invalid pattern" do
      LineEditor.matches_regexp?("anything", "(unclosed").should be_false
    end

    it "returns false when no pattern is given" do
      LineEditor.matches_regexp?("anything", nil).should be_false
    end
  end
end
