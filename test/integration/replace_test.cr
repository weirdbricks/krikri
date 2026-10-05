require "../minitest_helper"
require "file_utils"
require "system/user"

# The classic suite pre-created a shared spec/tmp/replace dir in
# before_suite; every test now gets its own tmp_path subtree.
private def fresh_file(name : String, content : String) : String
  path = PluginSpecHelper.tmp_path(name)
  File.write(path, content)
  path
end

# The classic suite kept its files in a shared spec/tmp/replace dir that
# before_suite created; the minitest equivalent is a per-test "replace"
# subtree under tmp_path, created on first use.
private def replace_dir : String
  dir = PluginSpecHelper.tmp_path("replace")
  FileUtils.mkdir_p(dir)
  dir
end

describe "replace plugin" do
  it "replaces a regex match in the file" do
    path = fresh_file("one.conf", "  gpgcheck = 0\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^\\s*gpgcheck.*", "replace" => "gpgcheck=1"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("gpgcheck=1\n")
  end

  it "interprets Python re.sub control escapes in the replacement (round900159 juju4.harden_apache)" do
    # Real replace.py runs `replace:` through Python re.sub's own
    # replacement-template parser, so a YAML single-quoted '\t' (two
    # literal chars) lands in the file as a REAL tab byte - this engine
    # used to write the literal backslash-t, which then failed
    # `apache2ctl -t` with `Invalid command '\tOptions'` on
    # apache2.conf. Note the Crystal source "\\t" below is exactly the
    # two-character sequence a single-quoted YAML value carries.
    path = fresh_file("escapes.conf", "XOptions Foo\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^X", "replace" => "\\tY\\nZ\\r"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("\tY\nZ\rOptions Foo\n")
  end

  it "still substitutes \\1 backreferences in the replacement" do
    # The escape-interpretation pass must not consume digits Crystal's own
    # gsub parser needs: \1 reaches scan_backreferences untouched.
    path = fresh_file("backref.conf", "Xq\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "(X)q", "replace" => "\\1-y"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("X-y\n")
  end

  it "turns a literal \\\\ in the replacement into one backslash (not double-processed)" do
    path = fresh_file("backslash.conf", "Xq\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^X", "replace" => "a\\\\b"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("a\\bq\n")
  end

  it "reports changed: false on an idempotent rerun" do
    path = fresh_file("idem.conf", "gpgcheck=1\n")
    params = {"path" => path, "regexp" => "^\\s*gpgcheck.*", "replace" => "gpgcheck=1"}
    PluginSpecHelper.run("replace", params)

    result = PluginSpecHelper.run("replace", params)

    result["changed"].as_bool.must_equal(false)
  end

  it "anchors ^ and $ at line boundaries (Ansible's re.MULTILINE)" do
    # The inmotionhosting.wordpress round-82013 divergence: Ansible's
    # replace.py compiles with re.MULTILINE, so "Listen 443$" matches the
    # tab-indented Listen lines inside <IfModule> blocks mid-file; without
    # MULTILINE only an end-of-file match counts and the task misreports ok.
    path = fresh_file("ports.conf", "Listen 80\n\n<IfModule ssl_module>\n\tListen 443\n</IfModule>\n\n<IfModule mod_gnutls.c>\n\tListen 443\n</IfModule>\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "Listen 443$", "replace" => "Listen 8443"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("Listen 80\n\n<IfModule ssl_module>\n\tListen 8443\n</IfModule>\n\n<IfModule mod_gnutls.c>\n\tListen 8443\n</IfModule>\n")
  end

  it "reports changed: false when the replacement is identical to the match" do
    path = fresh_file("same.conf", "Listen 80\n\n<IfModule ssl_module>\n\tListen 443\n</IfModule>\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "Listen 443$", "replace" => "Listen 443"})

    result["changed"].as_bool.must_equal(false)
    File.read(path).must_equal("Listen 80\n\n<IfModule ssl_module>\n\tListen 443\n</IfModule>\n")
  end

  it "applies mode when given" do
    path = fresh_file("mode.conf", "x=1\n")
    File.chmod(path, 0o644)

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^x", "replace" => "y", "mode" => "0600"})

    result["changed"].as_bool.must_equal(true)
    (File.info(path, follow_symlinks: false).permissions.value & 0o777).must_equal(0o600)
  end

  it "appends the ownership/perms suffix when content and mode both changed" do
    # Real replace.py runs check_file_attrs AFTER write_changes, whose
    # atomic_move preserves the dest's old mode - so the task's mode: is
    # a real post-write drift and check_file_attrs appends the suffix.
    # This engine used to pre-apply the task's numeric mode onto the
    # staging temp, apply_attributes saw no drift, and the msg was a
    # bare "N replacements made" (live-verified vs 2.19.11 at -v).
    path = fresh_file("content_and_attrs.conf", "gpgcheck=0\n")
    File.chmod(path, 0o644)

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^gpgcheck", "replace" => "gpgcheck=1", "mode" => "0600"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("1 replacements made and ownership, perms or SE linux context changed")
    (File.info(path).permissions.value & 0o777).must_equal(0o600)
  end

  it "reports the bare suffix as the whole msg when only the attrs changed" do
    # Real: changed starts false, check_file_attrs flips it and the empty
    # message gets only the suffix (no leading " and ").
    path = fresh_file("attrs_only.conf", "a=1\n")
    File.chmod(path, 0o644)

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^nomatch", "replace" => "x", "mode" => "0600"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("ownership, perms or SE linux context changed")
    (File.info(path).permissions.value & 0o777).must_equal(0o600)
  end

  it "adds no suffix when the requested mode already matches the file" do
    # Ansible's set_file_attributes_if_different returns False when nothing
    # actually drifted, so a re-run with no content change and the mode
    # already in place is a plain ok with an empty msg.
    path = fresh_file("mode_already.conf", "a=1\n")
    File.chmod(path, 0o600)

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^nomatch", "replace" => "x", "mode" => "0600"})

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("")
  end

  it "accepts owner/group (applied on disk) and reports no stat fields (add_file_common_args)" do
    me = System::User.find_by?(id: LibC.getuid.to_s).try(&.username) || ENV["USER"]? || "root"
    path = fresh_file("owner.conf", "x=1\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^x", "replace" => "y", "owner" => me, "group" => me, "mode" => "0600"})

    result["failed"]?.must_be_nil
    # The attributes are applied to the file, but Ansible's replace result
    # is only {changed, failed, msg, rc} - it never merges the
    # add_path_info stat fields nor echoes owner/group/mode
    # (live-verified vs 2.19.11 at -v). Assert both halves: the
    # on-disk effect and the absence of the stat keys.
    (File.info(path).permissions.value & 0o777).must_equal(0o600)
    result["rc"].as_i64.must_equal(0)
    result["owner"]?.must_be_nil
    result["group"]?.must_be_nil
    result["mode"]?.must_be_nil
    result["size"]?.must_be_nil
  end

  it "restricts substitution to content after the first `after` match" do
    path = fresh_file("after.conf", "keep-a=1\n[main]\nchange-a=1\nchange-b=1\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "after" => "\\[main\\]", "regexp" => "^change-", "replace" => "fixed-"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("keep-a=1\n[main]\nfixed-a=1\nfixed-b=1\n")
  end

  it "restricts substitution to content before the last `before` match" do
    # Python's greedy `(?P<subsection>.*)before` under re.search anchors the
    # section at position 0 and backtracks to the LAST occurrence of before.
    path = fresh_file("before.conf", "change-a=1\nchange-b=1\n[main]\nkeep-b=1\n[main]\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "before" => "\\[main\\]", "regexp" => "^change-", "replace" => "fixed-"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("fixed-a=1\nfixed-b=1\n[main]\nkeep-b=1\n[main]\n")
  end

  it "restricts substitution to the region between after and before (both given)" do
    path = fresh_file("both.conf", "<VirtualHost *>\n  Line1\n  Line2\n</VirtualHost>\nother\n")

    # after/before are compiled with re.DOTALL only (no re.MULTILINE) in
    # Ansible - `^`/`$` inside them anchor to the whole-content
    # start/end, not line boundaries, so unanchored literals are used here
    # (live-verified against real Python's re module with this exact
    # module.py pattern-construction logic).
    result = PluginSpecHelper.run("replace", {"path" => path, "after" => "<VirtualHost \\*>", "before" => "</VirtualHost>", "regexp" => "^(.+)$", "replace" => "# \\1"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("<VirtualHost *>\n#   Line1\n#   Line2\n</VirtualHost>\nother\n")
  end

  it "reports changed: false (not failed) when before/after matches nothing" do
    path = fresh_file("nomatch.conf", "a=1\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "after" => "NOPE", "regexp" => "^a", "replace" => "b"})

    result["changed"].as_bool.must_equal(false)
    result["failed"]?.must_be_nil
    result["msg"].as_s.must_include("did not match the given file")
    File.read(path).must_equal("a=1\n")
  end

  it "creates a timestamped backup and reports backup_file when backup: yes" do
    path = fresh_file("backup.conf", "gpgcheck=0\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "gpgcheck=0", "replace" => "gpgcheck=1", "backup" => "yes"})

    result["changed"].as_bool.must_equal(true)
    backup_file = result["backup_file"].as_s
    File.exists?(backup_file).must_equal(true)
    File.read(backup_file).must_equal("gpgcheck=0\n")
    File.read(path).must_equal("gpgcheck=1\n")
  end

  it "creates no backup and reports no backup_file key without backup: yes" do
    path = File.join(replace_dir, "nobackup.conf")
    File.write(path, "gpgcheck=0\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "gpgcheck=0", "replace" => "gpgcheck=1"})

    result["changed"].as_bool.must_equal(true)
    # Ansible's replace only ever sets backup_file when backup: yes was
    # given (the Ansible module backs up conditionally, then
    # exit_json(backup_file=...) only inside that branch) - without it
    # the key is absent entirely, not empty
    # (live-verified vs 2.19.11 at -v).
    result["backup_file"]?.must_be_nil
    Dir[File.join(PluginSpecHelper.tmp_path("replace"), "nobackup.conf*")].size.must_equal(1)
  end

  it "passes validation and writes the file (validate: with %s)" do
    path = fresh_file("validate-ok.conf", "value=1\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "value=1", "replace" => "value=2", "validate" => "grep -q '^value=2' %s"})

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("value=2\n")
  end

  it "fails validation and leaves the real file untouched" do
    path = fresh_file("validate-fail.conf", "value=BAD\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^value=.*", "replace" => "value=STILL_BAD", "validate" => "! grep -q 'BAD' %s"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("failed to validate")
    File.read(path).must_equal("value=BAD\n")
  end

  it "fails when validate does not contain %s" do
    path = fresh_file("validate-nos.conf", "value=1\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "value=1", "replace" => "value=2", "validate" => "/bin/true"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("validate must contain %s")
  end

  it "reads and writes with the given encoding" do
    path = File.join(replace_dir, "encoding.txt")
    File.write(path, "caf".to_slice + Bytes[0xe9] + "=1".to_slice)

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "=1", "replace" => "=2", "encoding" => "latin1"})

    result["changed"].as_bool.must_equal(true)
    bytes = File.read(path).to_slice
    bytes[-1].must_equal('2'.ord)
    bytes[3].must_equal(0xe9)
  end

  it "fails when the file doesn't exist" do
    result = PluginSpecHelper.run("replace", {"path" => File.join(PluginSpecHelper.tmp_path("replace"), "nope.txt"), "regexp" => "x", "replace" => "y"})

    result["failed"].as_bool.must_equal(true)
  end

  it "fails when regexp is missing" do
    path = fresh_file("noregexp.txt", "x")
    result = PluginSpecHelper.run("replace", {"path" => path})

    result["failed"].as_bool.must_equal(true)
  end

  it "rejects parameters outside replace's own argument_spec (ignorecase is lineinfile's, msg live-verified)" do
    path = fresh_file("ignorecase.txt", "hue\n")
    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "hue", "replace" => "x", "ignorecase" => "true"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Unsupported parameters for (ansible.builtin.replace) module: ignorecase. " \
                                  "Supported parameters include: after, attributes, backup, before, encoding, group, mode, owner, " \
                                  "path, regexp, replace, selevel, serole, setype, seuser, unsafe_writes, validate " \
                                  "(attr, dest, destfile, name).")
    File.read(path).must_equal("hue\n")
  end

  # The two krikri-playbook-generator round-31 divergences (module
  # replace) both landed on the same shape of gap: real replace.py runs
  # its arguments through Python's OWN machinery (bytes.decode for
  # encoding:, re.sub's replacement-template parser for replace:), and
  # every wording below is live-verified against ansible-core 2.19.11.

  it "fails with Ansible's module-crash wording on an encoding Python has no codec for" do
    # real decodes the file's bytes inside to_text(), so an unknown
    # codec name dies with a LookupError its own `except OSError` does
    # not catch - the module-crash path, not fail_json. This engine
    # used to fail with its own "Failed to read <path>: Invalid
    # encoding: <name>".
    path = fresh_file("enc_unknown.txt", "value=1\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "=1", "replace" => "=2", "encoding" => "20"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Task failed: Module failed: unknown encoding: 20")
    result["_ansible_error_detail"].as_s.must_equal("unknown encoding: 20")
    File.read(path).must_equal("value=1\n")
  end

  it "accepts Python's codec aliases, which iconv does not take verbatim" do
    # glibc's iconv rejects "latin-1"/"us-ascii" while CPython's
    # codecs.lookup() resolves both - so the unknown-codec verdict has
    # to come from Python's own registry (Krikri::PythonCodecs), not
    # from iconv. The content is written as raw latin-1 bytes to prove
    # the read/write round trip.
    path = File.join(replace_dir, "enc_alias.txt")
    File.write(path, "caf".to_slice + Bytes[0xe9] + "=1".to_slice)

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "=1", "replace" => "=2", "encoding" => "latin-1"})

    result["changed"].as_bool.must_equal(true)
    bytes = File.read(path).to_slice
    bytes[3].must_equal(0xe9)
    bytes[-1].must_equal('2'.ord)
  end

  it "fails an unsatisfiable group reference even when the regexp matches nothing" do
    # real re.subn parses the replacement template BEFORE it applies
    # the pattern, so `replace: '\1 changed'` against a pattern with no
    # capture groups fails the task (and leaves the file alone) whatever
    # the file holds. This engine used to write the substitution out
    # with an empty group instead.
    path = fresh_file("groupref.txt", "kpg here\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "nomatchatall", "replace" => "\\1 changed"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Unable to process replace due to error: invalid group reference 1 at position 1")
    File.read(path).must_equal("kpg here\n")
  end

  it "expands Python's \\g<n> group reference spelling" do
    # `\g<1>` is Python's unambiguous form of `\1` (a digit right after
    # a backreference would otherwise start a longer one), and `\g<name>`
    # resolves against the pattern's own named group.
    numbered = fresh_file("gref_numbered.txt", "kpg here\n")
    numbered_result = PluginSpecHelper.run("replace", {"path" => numbered, "regexp" => "(kpg) here", "replace" => "\\g<1>2"})

    numbered_result["changed"].as_bool.must_equal(true)
    File.read(numbered).must_equal("kpg2\n")

    named = fresh_file("gref_named.txt", "kpg here\n")
    named_result = PluginSpecHelper.run("replace", {"path" => named, "regexp" => "(?P<word>kpg) here", "replace" => "\\g<word>!"})

    named_result["changed"].as_bool.must_equal(true)
    File.read(named).must_equal("kpg!\n")
  end

  it "fails with Ansible's module-crash wording on a group name the pattern does not define" do
    # The IndexError for an unknown group name escapes replace.py's own
    # `except re.error`, so it is a module crash rather than a
    # fail_json - the fatal msg keeps Ansible's "Task failed: Module
    # failed: " wrapper while the [ERROR] block shows the bare text
    # (carried in _ansible_error_detail).
    path = fresh_file("groupname.txt", "kpg here\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "(kpg)", "replace" => "\\g<nope>"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Task failed: Module failed: unknown group name 'nope'")
    result["_ansible_error_detail"].as_s.must_equal("unknown group name 'nope'")
    File.read(path).must_equal("kpg here\n")
  end

  it "reports a bad escape in the replacement the way re.sub does" do
    # re.ESCAPES has no entry for an unknown LETTER, so Python raises
    # "bad escape \q"; a trailing lone backslash is the tokenizer's own
    # "bad escape (end of pattern)". Both positions are counted the way
    # re._parser.Tokenizer#tell counts them.
    bad_letter = fresh_file("bad_escape.txt", "kpg\n")
    bad_letter_result = PluginSpecHelper.run("replace", {"path" => bad_letter, "regexp" => "kpg", "replace" => "\\q"})

    bad_letter_result["failed"].as_bool.must_equal(true)
    bad_letter_result["msg"].as_s.must_equal("Unable to process replace due to error: bad escape \\q at position 0")
    File.read(bad_letter).must_equal("kpg\n")

    trailing = fresh_file("trailing_backslash.txt", "kpg\n")
    trailing_result = PluginSpecHelper.run("replace", {"path" => trailing, "regexp" => "kpg", "replace" => "a\\"})

    trailing_result["failed"].as_bool.must_equal(true)
    trailing_result["msg"].as_s.must_equal("Unable to process replace due to error: bad escape (end of pattern) at position 1")
    File.read(trailing).must_equal("kpg\n")
  end

  it "interprets an octal escape as a byte and keeps a non-letter escape literal" do
    # \101 is the byte 'A'; "\-" has no entry in re.ESCAPES and is not a
    # letter, so Ansible writes the backslash and the dash through as they
    # are (only an unknown LETTER is a "bad escape" there).
    path = fresh_file("octal.txt", "first\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "^first", "replace" => "\\101\\t\\-"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("A\t\\-\n")
  end

  # The kpg31-sweep "replace: leftovers" trio: real compiles the regexp
  # (and the composed before/after pattern) with Python's own re OUTSIDE
  # its `except re.error`, so every rejection below is an uncaught
  # re.error - the module-crash wrapper, live-verified vs 2.19.11 for
  # each wording.

  it "rejects the PCRE (?<name>...) group spelling like Ansible's Python re" do
    # Python only takes (?P<name>...); PCRE2 also accepts (?<name>...),
    # which this engine used to compile and RUN where Ansible fails.
    path = fresh_file("named_angle.txt", "bar baz\nbar\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "(?<foo>bar)", "replace" => "BAZ"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Task failed: Module failed: unknown extension ?<f at position 1")
    File.read(path).must_equal("bar baz\nbar\n")
  end

  it "rejects the PCRE (?'name'...) single-quote group spelling like Ansible's Python re" do
    path = fresh_file("named_quote.txt", "bar baz\nbar\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "(?'foo'bar)", "replace" => "BAZ"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: unknown extension ?' at position 1")
    File.read(path).must_equal("bar baz\nbar\n")
  end

  it "still accepts Python's own (?P<name>...) spelling" do
    path = fresh_file("named_p.txt", "bar baz\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "(?P<w>bar)", "replace" => "\\g<w>!"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("bar! baz\n")
  end

  it "reproduces Ansible's uncaught re.error module crash for a bad regexp" do
    # Position 10 is Python's own accounting: the index of the
    # unterminated '(' - not PCRE2's end-of-pattern offset.
    path = fresh_file("bad_regexp.txt", "hello world\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "unmatched (", "replace" => "X"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Task failed: Module failed: missing ), unterminated subpattern at position 10")
    File.read(path).must_equal("hello world\n")
  end

  it "reports a bad after: pattern through the crash wrapper, compiled before the regexp" do
    # real compiles the composed section pattern first, so a bad after:
    # crashes before the regexp is ever looked at; position 10 counts
    # into the COMPOSED pattern (after + (?P<subsection>...)). The
    # innermost unterminated '(' is the one the user wrote.
    path = fresh_file("bad_after.txt", "hello world\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "after" => "unmatched (", "regexp" => "x", "replace" => "X"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: missing ), unterminated subpattern at position 10")
    File.read(path).must_equal("hello world\n")
  end

  it "reports an unbalanced closing parenthesis like real" do
    path = fresh_file("stray_paren.txt", "hello world\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "x)", "replace" => "X"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: unbalanced parenthesis at position 1")
  end

  it "reports a trailing lone backslash in the pattern like real" do
    path = fresh_file("trailing_bs.txt", "hello world\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "a\\", "replace" => "X"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: bad escape (end of pattern) at position 1")
  end

  it "rejects PCRE-only escapes Python's re rejects (bad escape backslash-z)" do
    # \z is PCRE's absolute end anchor; Python's re has no \z in 3.13
    # (only \Z), so real crashes where this engine used to match
    # happily.
    path = fresh_file("bs_z.txt", "hello world\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "world\\z", "replace" => "WORLD"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Task failed: Module failed: bad escape \\z at position 5")
    File.read(path).must_equal("hello world\n")
  end

  it "rejects PCRE's \\x{...} brace form Python's re does not take" do
    path = fresh_file("brace_x.txt", "hello world\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "\\x{41}", "replace" => "X"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: incomplete escape \\x at position 0")
  end

  it "accepts Python's \\uhhhh escape spelling where PCRE2 has none" do
    # Python re supports \uhhhh (and \Uhhhhhhhh); PCRE2 does not, so
    # the pattern is rewritten to PCRE2's \x{...} before compiling -
    # real replaces here, and this engine used to die on the PCRE2
    # "does not support \u" error.
    path = File.join(replace_dir, "unicode_escape.txt")
    File.write(path, "café = 1\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "caf\\u00e9", "replace" => "CAFE"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("CAFE = 1\n")
  end

  it "reports an incomplete \\u escape the way Python's re does" do
    path = fresh_file("incomplete_u.txt", "hello world\n")

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "\\u12z", "replace" => "X"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: incomplete escape \\u12 at position 0")
  end

  it "decodes non-UTF-8 bytes with surrogateescape semantics under the default encoding" do
    # real decodes the file's bytes with errors="surrogateescape", so a
    # latin-1 byte inside a utf-8-decoded file becomes one surrogate
    # character and the substitution proceeds; the byte round-trips on
    # write. This engine used to abort with a PCRE "UTF-8 error" the
    # moment the regex touched the decoded bytes.
    path = File.join(replace_dir, "surrogate_latin1.txt")
    File.write(path, "caf".to_slice + Bytes[0xe9] + " done\nnext line\n".to_slice)

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "done$", "replace" => "DONE"})

    result["changed"].as_bool.must_equal(true)
    bytes = File.read(path).to_slice
    bytes[3].must_equal(0xe9)
    String.new(bytes).must_equal("caf\xE9 DONE\nnext line\n")
  end

  it "matches one undecodable byte with . like Ansible's surrogate does" do
    path = File.join(replace_dir, "surrogate_dot.txt")
    File.write(path, "caf".to_slice + Bytes[0xe9] + " done\n".to_slice)

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "caf. done", "replace" => "CAFE DONE"})

    result["changed"].as_bool.must_equal(true)
    String.new(File.read(path).to_slice).must_equal("CAFE DONE\n")
  end

  it "keeps the byte round trip for a codec iconv cannot convert (mac_roman)" do
    # mac_roman is in Python's codec registry but has no iconv
    # converter here: the bytes are read raw and the substitution still
    # proceeds (real decodes through the real codec; for an untouched
    # high byte the file's bytes come out identical either way).
    path = File.join(replace_dir, "mac_roman.txt")
    File.write(path, "caf".to_slice + Bytes[0xe9] + "=1".to_slice)

    result = PluginSpecHelper.run("replace", {"path" => path, "regexp" => "=1", "replace" => "=2", "encoding" => "mac_roman"})

    result["changed"].as_bool.must_equal(true)
    bytes = File.read(path).to_slice
    bytes[3].must_equal(0xe9)
    bytes[-1].must_equal('2'.ord)
  end
end
