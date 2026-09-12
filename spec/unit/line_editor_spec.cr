require "../spec_helper"
require "../../src/krikri/plugin_helpers/line_editor"

private alias LineEditor = Krikri::PluginHelpers::LineEditor

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

    it "replaces the LAST line matching the regexp, not the first (matches real Ansible's lineinfile)" do
      # Found live benchmarking geerlingguy.phpmyadmin: its "Add default
      # username and password for MySQL connection." lineinfile tasks use
      # regexp `^.+\[['"]host['"]\].+$`, which matches BOTH the package's
      # populated `['host'] = $dbserver;` line and the commented
      # `// ...['host'] = 'localhost';` template near EOF. Real ansible
      # only rewrites the last matching line; crystal previously rewrote
      # the first, producing a config.inc.php that diverged byte-for-byte.
      lines = [
        "$cfg['Servers'][$i]['host'] = $dbserver;",
        "// $cfg['Servers'][$i]['host'] = 'localhost';",
      ]
      out, changed = LineEditor.ensure_present(
        lines,
        "$cfg['Servers'][$i]['host'] = '127.0.0.1';",
        "^.+\\[['\"]host['\"]\\].+$",
        false, nil, nil
      )
      out[0].should eq("$cfg['Servers'][$i]['host'] = $dbserver;")
      out[1].should eq("$cfg['Servers'][$i]['host'] = '127.0.0.1';")
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

    it "backrefs replace the WHOLE line, not just the regexp-matched span" do
      # Real bug found benchmarking riemers.gitlab-runner's own "Set
      # concurrent option": `regexp: ^(\s*)concurrent =`, `line:
      # \1concurrent = 5`, backrefs: true against "concurrent = 1" -
      # the regexp only matches the "concurrent =" prefix, not the
      # whole line. Real Ansible's backrefs mode expands `line:`'s own
      # backreferences and uses that as the COMPLETE new line
      # (Python's `match.expand(line)`); this previously used
      # `String#gsub(Regex, String)`, which replaces only the matched
      # SPAN and leaves whatever wasn't matched (here, the " 1" value
      # after the matched "concurrent =" prefix) appended verbatim -
      # producing the corrupt "concurrent = 5 1" (invalid TOML;
      # gitlab-runner itself then failed to parse its own config on
      # every later run).
      lines, changed = LineEditor.ensure_present(["concurrent = 1"], "\\1concurrent = 5", "^(\\s*)concurrent =", true, nil, nil)
      lines.should eq(["concurrent = 5"])
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

    it "reports unchanged when regexp: is given but doesn't match, and the exact line already exists elsewhere" do
      # Real bug found benchmarking geerlingguy.jenkins: its own "Modify
      # variables in init file." task gives a regexp: that never
      # actually matches the already-installed line (a trailing space
      # in the role's own regexp: - `^Environment="JENKINS_OPTS ` -
      # doesn't match the real line's `Environment="JENKINS_OPTS="`, no
      # space before the `=`), while line: is the exact text already
      # present. The "already present" dedup check was gated behind
      # `!regexp` - since a regexp: WAS given here (it just never
      # matched anything), the check was skipped entirely and a fresh
      # duplicate got appended on every single run, never converging.
      lines, changed = LineEditor.ensure_present(
        ["Environment=\"JENKINS_OPTS=\""],
        "Environment=\"JENKINS_OPTS=\"",
        "^Environment=\"JENKINS_OPTS ",
        false, nil, nil
      )
      lines.should eq(["Environment=\"JENKINS_OPTS=\""])
      changed.should be_false
    end

    it "replaces the FIRST line matching the regexp when firstmatch is set (live-verified against ansible-core 2.19.4)" do
      # Confirmed live krikri bug: real ansible-playbook 2.19.4 with
      # regexp '^foo=' against "foo=1/bar=2/foo=3/baz=4" and
      # firstmatch: true rewrites the FIRST "foo=" line; krikri
      # previously ignored firstmatch entirely and always replaced the
      # last.
      lines, changed = LineEditor.ensure_present(["foo=1", "bar=2", "foo=3", "baz=4"], "foo=REPLACED", "^foo=", false, nil, nil, true)
      lines.should eq(["foo=REPLACED", "bar=2", "foo=3", "baz=4"])
      changed.should be_true
    end

    it "honors firstmatch for the insertafter anchor too, inserting after the FIRST match (live-verified against ansible-core 2.19.4)" do
      lines, changed = LineEditor.ensure_present(["marker one", "junk", "marker two", "junk2"], "INSERTED", nil, false, "^marker", nil, true)
      lines.should eq(["marker one", "INSERTED", "junk", "marker two", "junk2"])
      changed.should be_true
    end

    it "anchors the insertion at the LAST insertafter match by default (live-verified against ansible-core 2.19.4)" do
      # Real Ansible's insertafter loop keeps scanning and only stops
      # early under firstmatch - both lineinfile and blockinfile. The
      # previous first-match-always behavior diverged on any anchor
      # pattern matching more than one line.
      lines, changed = LineEditor.ensure_present(["marker one", "junk", "marker two", "junk2"], "INSERTED", nil, false, "^marker", nil)
      lines.should eq(["marker one", "junk", "marker two", "INSERTED", "junk2"])
      changed.should be_true
    end

    it "replaces the last line CONTAINING search_string (literal substring, not a regex)" do
      # Live-verified against ansible-core 2.19.4: search_string is a
      # plain substring containment check, and state=present replaces
      # the LAST line containing it, same last-match default as regexp.
      lines, changed = LineEditor.ensure_present(["alpha one", "beta", "alpha two"], "alpha REPLACED", nil, false, nil, nil, false, "alpha")
      lines.should eq(["alpha one", "beta", "alpha REPLACED"])
      changed.should be_true
    end

    it "replaces the first line CONTAINING search_string when firstmatch is set" do
      lines, changed = LineEditor.ensure_present(["alpha one", "beta", "alpha two"], "alpha REPLACED", nil, false, nil, nil, true, "alpha")
      lines.should eq(["alpha REPLACED", "beta", "alpha two"])
      changed.should be_true
    end

    it "treats search_string as a literal, not a regex pattern" do
      # "a+b" as a regexp would match "aaab"; as a search_string it
      # only matches a literal "a+b".
      lines, changed = LineEditor.ensure_present(["aaab", "keep a+b"], "x", nil, false, nil, nil, false, "a+b")
      lines.should eq(["aaab", "x"])
      changed.should be_true
    end

    it "search_string that matches nothing falls through to insertafter insertion" do
      lines, changed = LineEditor.ensure_present(["header", "footer"], "new line", nil, false, "^header", nil, false, "nomatch")
      lines.should eq(["header", "new line", "footer"])
      changed.should be_true
    end

    it "search_string hit equal to the desired line reports unchanged" do
      lines, changed = LineEditor.ensure_present(["port = 2222", "comment"], "port = 2222", nil, false, nil, nil, false, "port")
      lines.should eq(["port = 2222", "comment"])
      changed.should be_false
    end
  end

  describe ".remove_matching (search_string)" do
    it "removes every line containing search_string (firstmatch has no effect on state=absent - live-verified against ansible-core 2.19.4)" do
      lines, changed = LineEditor.remove_matching(["keep", "alpha one", "keep2", "alpha two"], nil, nil, "alpha")
      lines.should eq(["keep", "keep2"])
      changed.should be_true
    end

    it "removes every line matching regexp even though firstmatch never applies to state=absent" do
      lines, changed = LineEditor.remove_matching(["keep", "foo=1", "keep2", "foo=2"], nil, "^foo=")
      lines.should eq(["keep", "keep2"])
      changed.should be_true
    end

    it "when regexp is given it decides alone - search_string and line are not consulted (real Ansible's matcher chain)" do
      lines, changed = LineEditor.remove_matching(["rx here", "substring here", "exact"], "exact", "^rx", "substring")
      lines.should eq(["substring here", "exact"])
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
