require "../minitest_helper"
require "../../src/krikri/plugin_helpers/line_editor"

private alias LineEditor = Krikri::PluginHelpers::LineEditor

describe LineEditor do
  describe ".split_lines" do
    it "keeps terminators attached, like Ansible's binary-mode readlines" do
      LineEditor.split_lines("a\nb\n").must_equal(["a\n", "b\n"])
      LineEditor.split_lines("a\r\nb\r\n").must_equal(["a\r\n", "b\r\n"])
      LineEditor.split_lines("a\nb").must_equal(["a\n", "b"])
      LineEditor.split_lines("a\r").must_equal(["a\r"])
      LineEditor.split_lines("").must_equal([] of String)
      LineEditor.split_lines("\n").must_equal(["\n"])
    end
  end

  describe ".remove_matching" do
    it "removes an exact match (rstrip \\r\\n compare, no whitespace normalization) and reports changed" do
      lines, changed, found = LineEditor.remove_matching(["keep me\n", "remove me\n"], "remove me", nil)
      lines.must_equal(["keep me\n"])
      changed.must_equal(true)
      found.must_equal(1)
    end

    it "removes every line matching a regexp (searched against the terminated line)" do
      lines, changed, found = LineEditor.remove_matching(["a=1\n", "b=2\n", "a=3\n"], nil, "^a=")
      lines.must_equal(["b=2\n"])
      changed.must_equal(true)
      found.must_equal(2)
    end

    it "reports unchanged when nothing matches" do
      lines, changed, found = LineEditor.remove_matching(["keep me\n"], "not here", nil)
      lines.must_equal(["keep me\n"])
      changed.must_equal(false)
      found.must_equal(0)
    end

    it "matches a CRLF line by exact line: (the trailing \\r is stripped for the comparison only)" do
      lines, changed, _found = LineEditor.remove_matching(["en\r\n"], "en", nil)
      lines.must_equal([] of String)
      changed.must_equal(true)
    end

    it "does not match a whitespace-padded line by exact line: (Ansible compares raw bytes minus \\r\\n)" do
      lines, changed, _found = LineEditor.remove_matching(["en \n"], "en", nil)
      lines.must_equal(["en \n"])
      changed.must_equal(false)
    end
  end

  describe ".ensure_present" do
    it "reports unchanged when the exact line already exists" do
      lines, changed, msg = LineEditor.ensure_present(["hello world\n"], "hello world", nil, nil, nil, nil, false, false)
      lines.must_equal(["hello world\n"])
      changed.must_equal(false)
      msg.must_equal("")
    end

    it "appends the line when it is missing and no insertion point is given" do
      lines, changed, msg = LineEditor.ensure_present(["existing\n"], "new line", nil, nil, nil, nil, false, false)
      lines.must_equal(["existing\n", "new line\n"])
      changed.must_equal(true)
      msg.must_equal("line added")
    end

    it "appends to an empty file with exactly one trailing newline (create: yes path)" do
      lines, changed, msg = LineEditor.ensure_present([] of String, "en", "^(en|ja|cn)$", nil, nil, nil, false, false)
      lines.must_equal(["en\n"])
      changed.must_equal(true)
      msg.must_equal("line added")
    end

    it "replaces the line matched by regexp" do
      lines, changed, msg = LineEditor.ensure_present(["port=22\n"], "port=2222", "^port=", nil, nil, nil, false, false)
      lines.must_equal(["port=2222\n"])
      changed.must_equal(true)
      msg.must_equal("line replaced")
    end

    it "replaces the LAST line matching the regexp, not the first (matches Ansible's lineinfile)" do
      # Found live benchmarking geerlingguy.phpmyadmin: its "Add default
      # username and password for MySQL connection." lineinfile tasks use
      # regexp `^.+\[['"]host['"]\].+$`, which matches BOTH the package's
      # populated `['host'] = $dbserver;` line and the commented
      # `// ...['host'] = 'localhost';` template near EOF. Ansible
      # only rewrites the last matching line; crystal previously rewrote
      # the first, producing a config.inc.php that diverged byte-for-byte.
      lines = [
        "$cfg['Servers'][$i]['host'] = $dbserver;\n",
        "// $cfg['Servers'][$i]['host'] = 'localhost';\n",
      ]
      out, changed, _msg = LineEditor.ensure_present(
        lines,
        "$cfg['Servers'][$i]['host'] = '127.0.0.1';",
        "^.+\\[['\"]host['\"]\\].+$",
        nil, nil, nil, false, false
      )
      out[0].must_equal("$cfg['Servers'][$i]['host'] = $dbserver;\n")
      out[1].must_equal("$cfg['Servers'][$i]['host'] = '127.0.0.1';\n")
      changed.must_equal(true)
    end

    it "leaves the file untouched when the regexp match already equals the desired line" do
      lines, changed, _msg = LineEditor.ensure_present(["port=22\n"], "port=22", "^port=", nil, nil, nil, false, false)
      lines.must_equal(["port=22\n"])
      changed.must_equal(false)
    end

    it "treats a line value with a trailing newline as already present (regression: konstruktoid.docker_rootless's folded-scalar docker alias - the trailing newline made the comparison fail, so every run rewrote the line and the file grew one newline per run)" do
      lines, changed, _msg = LineEditor.ensure_present(
        ["alias docker='sudo XDG_RUNTIME_DIR=\"/run/user/1000\"'\n"],
        "alias docker='sudo XDG_RUNTIME_DIR=\"/run/user/1000\"'\n",
        "^alias docker=", nil, nil, nil, false, false
      )
      lines.must_equal(["alias docker='sudo XDG_RUNTIME_DIR=\"/run/user/1000\"'\n"])
      changed.must_equal(false)
    end

    it "replaces one matched line with a multi-line value as Ansible does (a single element embedding the newlines)" do
      lines, changed, _msg = LineEditor.ensure_present(["old\n", "tail\n"], "new-a\nnew-b", "^old$", nil, nil, nil, false, false)
      lines.must_equal(["new-a\nnew-b\n", "tail\n"])
      changed.must_equal(true)
    end

    it "keeps Ansible's NON-idempotent multi-line replacement: the value re-matches its own first physical line and the file grows every run (live-verified against ansible-core 2.19.11 - the previous krikri span-check made this converge, diverging from real)" do
      value = "foo\nbar\nbaz\n"
      lines, changed, _msg = LineEditor.ensure_present(["foo\n", "bar\n", "baz\n", "\n"], value, "^foo", nil, nil, nil, false, false)
      lines.must_equal(["#{value}", "bar\n", "baz\n", "\n"])
      changed.must_equal(true)
    end

    it "substitutes backreferences instead of replacing the whole line" do
      lines, changed, _msg = LineEditor.ensure_present(["name=alice\n"], "name=\\1-updated", "name=(\\w+)", nil, nil, nil, true, false)
      lines.must_equal(["name=alice-updated\n"])
      changed.must_equal(true)
    end

    it "backrefs replace the WHOLE line, not just the regexp-matched span" do
      # Real bug found benchmarking riemers.gitlab-runner's own "Set
      # concurrent option": `regexp: ^(\s*)concurrent =`, `line:
      # \1concurrent = 5`, backrefs: true against "concurrent = 1" -
      # the regexp only matches the "concurrent =" prefix, not the
      # whole line. Ansible's backrefs mode expands `line:`'s own
      # backreferences and uses that as the COMPLETE new line
      # (Python's `match.expand(line)`); this previously used
      # `String#gsub(Regex, String)`, which replaces only the matched
      # SPAN and leaves whatever wasn't matched (here, the " 1" value
      # after the matched "concurrent =" prefix) appended verbatim -
      # producing the corrupt "concurrent = 5 1" (invalid TOML;
      # gitlab-runner itself then failed to parse its own config on
      # every later run).
      lines, changed, _msg = LineEditor.ensure_present(["concurrent = 1\n"], "\\1concurrent = 5", "^(\\s*)concurrent =", nil, nil, nil, true, false)
      lines.must_equal(["concurrent = 5\n"])
      changed.must_equal(true)
    end

    it "expands escape sequences in the backrefs template the way Python match.expand does" do
      # Real bug found by testing/perf/modules_files.yml's divergence
      # probe: `line: 'MaxAuthTriesProbe \1\nMaxAuthTriesProbeBench \1'`
      # with backrefs must expand BOTH the \1 groups AND the \n escape -
      # Ansible writes two physical lines; the old expansion only
      # handled \N group refs and left `\n` as two literal characters.
      lines, changed, _msg = LineEditor.ensure_present(
        ["MaxAuthTriesProbe 6\n"],
        "MaxAuthTriesProbe \\1\\nMaxAuthTriesProbeBench \\1",
        "^MaxAuthTriesProbe (\\d+)$", nil, nil, nil, true, false
      )
      lines.must_equal(["MaxAuthTriesProbe 6\nMaxAuthTriesProbeBench 6\n"])
      changed.must_equal(true)
    end

    it "expands standard control escapes (tab, carriage return) in the backrefs template" do
      lines, _changed, _msg = LineEditor.ensure_present(["key=6\n"], "key=\\1\\tvalue", "^key=(\\d+)$", nil, nil, nil, true, false)
      lines.must_equal(["key=6\tvalue\n"])
    end

    it "expands \\g<name> group references in the backrefs template" do
      lines, _changed, _msg = LineEditor.ensure_present(["host=example\n"], "\\g<1>extra", "^(host=)", nil, nil, nil, true, false)
      lines.must_equal(["host=extra\n"])
    end

    it "expands an unmatched capture group to the empty string (Python semantics)" do
      lines, _changed, _msg = LineEditor.ensure_present(["beta\n"], "<\\1><\\2>", "^(a)?(b)", nil, nil, nil, true, false)
      lines.must_equal(["<><b>\n"])
    end

    it "leaves unknown escape sequences literal instead of dropping them" do
      lines, _changed, _msg = LineEditor.ensure_present(["path=6\n"], "path=\\1\\d", "^path=(\\d+)$", nil, nil, nil, true, false)
      lines.must_equal(["path=6\\d\n"])
    end

    it "leaves the file untouched when backrefs is set but the regexp matches nothing" do
      lines, changed, msg = LineEditor.ensure_present(["keep\n"], "\\1new", "^nomatch$", nil, nil, nil, true, false)
      lines.must_equal(["keep\n"])
      changed.must_equal(false)
      msg.must_equal("")
    end

    it "inserts after a matching insertafter pattern" do
      lines, changed, _msg = LineEditor.ensure_present(["[section]\n", "a=1\n"], "b=2", nil, nil, "^a=", nil, false, false)
      lines.must_equal(["[section]\n", "a=1\n", "b=2\n"])
      changed.must_equal(true)
    end

    it "inserts at EOF when insertafter is EOF" do
      lines, changed, _msg = LineEditor.ensure_present(["a\n", "b\n"], "c", nil, nil, "EOF", nil, false, false)
      lines.must_equal(["a\n", "b\n", "c\n"])
      changed.must_equal(true)
    end

    it "inserts before a matching insertbefore pattern" do
      lines, changed, _msg = LineEditor.ensure_present(["a=1\n", "[section]\n"], "b=2", nil, nil, nil, "^\\[", false, false)
      lines.must_equal(["a=1\n", "b=2\n", "[section]\n"])
      changed.must_equal(true)
    end

    it "inserts at BOF when insertbefore is BOF" do
      lines, changed, _msg = LineEditor.ensure_present(["a\n", "b\n"], "z", nil, nil, nil, "BOF", false, false)
      lines.must_equal(["z\n", "a\n", "b\n"])
      changed.must_equal(true)
    end

    it "falls back to appending at the end when the insertafter pattern is not found" do
      lines, changed, _msg = LineEditor.ensure_present(["x\n"], "y", nil, nil, "^nomatch", nil, false, false)
      lines.must_equal(["x\n", "y\n"])
      changed.must_equal(true)
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
      lines, changed, _msg = LineEditor.ensure_present(
        ["Environment=\"JENKINS_OPTS=\"\n"],
        "Environment=\"JENKINS_OPTS=\"",
        "^Environment=\"JENKINS_OPTS ",
        nil, nil, nil, false, false
      )
      lines.must_equal(["Environment=\"JENKINS_OPTS=\"\n"])
      changed.must_equal(false)
    end

    it "replaces the FIRST line matching the regexp when firstmatch is set (live-verified against ansible-core 2.19.4)" do
      # Confirmed live krikri bug: ansible-playbook 2.19.4 with
      # regexp '^foo=' against "foo=1/bar=2/foo=3/baz=4" and
      # firstmatch: true rewrites the FIRST "foo=" line; krikri
      # previously ignored firstmatch entirely and always replaced the
      # last.
      lines, changed, _msg = LineEditor.ensure_present(["foo=1\n", "bar=2\n", "foo=3\n", "baz=4\n"], "foo=REPLACED", "^foo=", nil, nil, nil, false, true)
      lines.must_equal(["foo=REPLACED\n", "bar=2\n", "foo=3\n", "baz=4\n"])
      changed.must_equal(true)
    end

    it "honors firstmatch for the insertafter anchor too, inserting after the FIRST match (live-verified against ansible-core 2.19.4)" do
      lines, changed, _msg = LineEditor.ensure_present(["marker one\n", "junk\n", "marker two\n", "junk2\n"], "INSERTED", nil, nil, "^marker", nil, false, true)
      lines.must_equal(["marker one\n", "INSERTED\n", "junk\n", "marker two\n", "junk2\n"])
      changed.must_equal(true)
    end

    it "anchors the insertion at the LAST insertafter match by default (live-verified against ansible-core 2.19.4)" do
      # Ansible's insertafter loop keeps scanning and only stops
      # early under firstmatch - both lineinfile and blockinfile. The
      # previous first-match-always behavior diverged on any anchor
      # pattern matching more than one line.
      lines, changed, _msg = LineEditor.ensure_present(["marker one\n", "junk\n", "marker two\n", "junk2\n"], "INSERTED", nil, nil, "^marker", nil, false, false)
      lines.must_equal(["marker one\n", "junk\n", "marker two\n", "INSERTED\n", "junk2\n"])
      changed.must_equal(true)
    end

    it "replaces the last line CONTAINING search_string (literal substring, not a regex)" do
      # Live-verified against ansible-core 2.19.4: search_string is a
      # plain substring containment check, and state=present replaces
      # the LAST line containing it, same last-match default as regexp.
      lines, changed, _msg = LineEditor.ensure_present(["alpha one\n", "beta\n", "alpha two\n"], "alpha REPLACED", nil, "alpha", nil, nil, false, false)
      lines.must_equal(["alpha one\n", "beta\n", "alpha REPLACED\n"])
      changed.must_equal(true)
    end

    it "replaces the first line CONTAINING search_string when firstmatch is set" do
      lines, changed, _msg = LineEditor.ensure_present(["alpha one\n", "beta\n", "alpha two\n"], "alpha REPLACED", nil, "alpha", nil, nil, false, true)
      lines.must_equal(["alpha REPLACED\n", "beta\n", "alpha two\n"])
      changed.must_equal(true)
    end

    it "treats search_string as a literal, not a regex pattern" do
      # "a+b" as a regexp would match "aaab"; as a search_string it
      # only matches a literal "a+b".
      lines, changed, _msg = LineEditor.ensure_present(["aaab\n", "keep a+b\n"], "x", nil, "a+b", nil, nil, false, false)
      lines.must_equal(["aaab\n", "x\n"])
      changed.must_equal(true)
    end

    it "search_string that matches nothing falls through to insertafter insertion" do
      lines, changed, _msg = LineEditor.ensure_present(["header\n", "footer\n"], "new line", nil, "nomatch", "^header", nil, false, false)
      lines.must_equal(["header\n", "new line\n", "footer\n"])
      changed.must_equal(true)
    end

    it "search_string hit equal to the desired line reports unchanged" do
      lines, changed, _msg = LineEditor.ensure_present(["port = 2222\n", "comment\n"], "port = 2222", nil, "port", nil, nil, false, false)
      lines.must_equal(["port = 2222\n", "comment\n"])
      changed.must_equal(false)
    end

    # --- SoftEther lang.config regressions (round 2600001,
    # softasap.sa-vpn-softether): vpnserver/vpncmd write lang.config
    # BOM + CRLF on every startup, and Ansible reported changed on
    # BOTH the cold and the warm run while crystal reported ok - the
    # old stripped-lines comparison treated "en\r" as equal to "en". --

    it "replaces a CRLF-terminated matching line with its LF form and reports changed (regexp cannot match across the \\r)" do
      lines, changed, msg = LineEditor.ensure_present(["en\r\n"], "en", "^(en|ja|cn)$", nil, nil, nil, false, false)
      lines.must_equal(["en\n"])
      changed.must_equal(true)
      msg.must_equal("line replaced")
    end

    it "finds a CRLF line via the exact-line fallback (rstrip \\r\\n) and still replaces it when the bytes differ" do
      # The lang.config shape: regexp "^(en|ja|cn)$" does NOT match
      # "en\r\n", but the exact-line scan (rstrip \r\n) finds it, and
      # the byte comparison ("en\r\n" vs "en\n") reports changed.
      lines, changed, msg = LineEditor.ensure_present(["# c\r\n", "en\r\n", "\r\n"], "en", "^(en|ja|cn)$", nil, nil, nil, false, false)
      lines.must_equal(["# c\r\n", "en\n", "\r\n"])
      changed.must_equal(true)
      msg.must_equal("line replaced")
    end

    it "reports changed for a matching line missing its trailing newline (Ansible normalizes it to a terminated line)" do
      lines, changed, msg = LineEditor.ensure_present(["en"], "en", "^(en|ja|cn)$", nil, nil, nil, false, false)
      lines.must_equal(["en\n"])
      changed.must_equal(true)
      msg.must_equal("line replaced")
    end

    it "appends the line when the existing line carries trailing whitespace (never converges, like Ansible)" do
      lines, changed, msg = LineEditor.ensure_present(["en \n"], "en", "^(en|ja|cn)$", nil, nil, nil, false, false)
      lines.must_equal(["en \n", "en\n"])
      changed.must_equal(true)
      msg.must_equal("line added")
    end

    it "appends the line when a BOM precedes the language token (the regexp is anchored at ^)" do
      lines, changed, _msg = LineEditor.ensure_present(["\xef\xbb\xbfen\r\n"], "en", "^(en|ja|cn)$", nil, nil, nil, false, false)
      lines.must_equal(["\xef\xbb\xbfen\r\n", "en\n"])
      changed.must_equal(true)
    end
  end

  describe ".remove_matching (search_string)" do
    it "removes every line containing search_string (firstmatch has no effect on state=absent - live-verified against ansible-core 2.19.4)" do
      lines, changed, found = LineEditor.remove_matching(["keep\n", "alpha one\n", "keep2\n", "alpha two\n"], nil, nil, "alpha")
      lines.must_equal(["keep\n", "keep2\n"])
      changed.must_equal(true)
      found.must_equal(2)
    end

    it "removes every line matching regexp even though firstmatch never applies to state=absent" do
      lines, changed, _found = LineEditor.remove_matching(["keep\n", "foo=1\n", "keep2\n", "foo=2\n"], nil, "^foo=")
      lines.must_equal(["keep\n", "keep2\n"])
      changed.must_equal(true)
    end

    it "when regexp is given it decides alone - search_string and line are not consulted (Ansible's matcher chain)" do
      lines, changed, _found = LineEditor.remove_matching(["rx here\n", "substring here\n", "exact\n"], "exact", "^rx", "substring")
      lines.must_equal(["substring here\n", "exact\n"])
      changed.must_equal(true)
    end
  end

  describe ".matches_regexp?" do
    it "returns false instead of raising for an invalid pattern" do
      LineEditor.matches_regexp?("anything", "(unclosed").must_equal(false)
    end

    it "returns false when no pattern is given" do
      LineEditor.matches_regexp?("anything", nil).must_equal(false)
    end
  end
end
