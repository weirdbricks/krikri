require "../minitest_helper"
require "file_utils"
require "digest"

# The classic suite built the fixture tree once in before_suite under a
# shared spec/tmp/find; minitest runs tests concurrently, so a private
# def hands every test its own tmp_path subtree (built fresh).
private def tmp_dir : String
  dir = PluginSpecHelper.tmp_path("find")
  Dir.mkdir_p(File.join(dir, "sub", "subsub"))
  File.write(File.join(dir, "a.txt"), "a")
  File.write(File.join(dir, "b.log"), "b")
  File.write(File.join(dir, "sub", "c.txt"), "c")
  File.write(File.join(dir, "sub", ".hidden.txt"), "hidden")
  File.write(File.join(dir, "sub", "subsub", "d.txt"), "d")
  dir
end

private def paths_of(result : JSON::Any) : Array(String)
  result["files"].as_a.map(&.["path"].as_s).sort!
end

private def with_follow_fixture : String
  target = File.join(tmp_dir, "follow_target")
  Dir.mkdir_p(target)
  File.write(File.join(target, "t.txt"), "t")

  link = File.join(tmp_dir, "follow_link")
  File.delete(link) if File.symlink?(link)
  File.symlink(target, link)
  link
end

describe "find plugin" do
  it "matches top-level files only, non-recursively, by default" do
    result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "*.txt"})

    result["matched"].as_i64.must_equal(1)
    paths_of(result).must_equal([File.join(tmp_dir, "a.txt")])
  end

  it "accepts the singular path= alias for paths=" do
    # Ansible's find module declares `paths` with aliases `path`
    # and `name` - a single-directory search almost always uses the
    # singular form. Found via robertdebock.dovecot's own "Find users
    # in /var/spool/mail" task (`path: /var/spool/mail`), which
    # Ansible accepts transparently; this plugin only ever recognized
    # the plural `paths:`, failing outright.
    result = PluginSpecHelper.run("find", {"path" => tmp_dir, "patterns" => "*.txt"})

    result["matched"].as_i64.must_equal(1)
    paths_of(result).must_equal([File.join(tmp_dir, "a.txt")])
  end

  it "recurses into subdirectories when recurse: true" do
    result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "*.txt", "recurse" => "true"})

    paths_of(result).must_equal([
      File.join(tmp_dir, "a.txt"),
      File.join(tmp_dir, "sub", "c.txt"),
      File.join(tmp_dir, "sub", "subsub", "d.txt"),
    ].sort)
  end

  it "excludes hidden files by default, even when recursing" do
    result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "*.txt", "recurse" => "true"})

    paths_of(result).wont_include(File.join(tmp_dir, "sub", ".hidden.txt"))
  end

  it "includes hidden files when hidden: true" do
    result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "*.txt", "recurse" => "true", "hidden" => "true"})

    paths_of(result).must_include(File.join(tmp_dir, "sub", ".hidden.txt"))
  end

  it "does not exclude anything when excludes is unset (regression: an empty excludes list must not exclude everything)" do
    result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "*.txt"})

    result["matched"].as_i64.must_equal(1)
  end

  it "filters out basenames matching excludes" do
    result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "*", "excludes" => "*.log"})

    paths_of(result).wont_include(File.join(tmp_dir, "b.log"))
    paths_of(result).must_include(File.join(tmp_dir, "a.txt"))
  end

  it "accepts the singular pattern= alias for patterns=" do
    # Ansible's find declares `pattern` as an alias of `patterns` in
    # its argument_spec (like paths' `path`/`name` above); a hardcoded
    # single-pattern search almost always uses the singular spelling.
    # Found via robertdebock.forensics (`pattern: ".authorized_keys"`),
    # which this plugin silently ignored - matching every file - while
    # real Ansible matched nothing.
    dir = PluginSpecHelper.tmp_path("find-pattern-alias")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "a.cfg"), "a")
    File.write(File.join(dir, ".history"), "h")
    result = PluginSpecHelper.run("find", {"paths" => dir, "pattern" => ".history", "hidden" => "true"})

    paths_of(result).must_equal([File.join(dir, ".history")])
  end

  it "pattern= restricts matching like patterns= (zero files when nothing matches)" do
    dir = PluginSpecHelper.tmp_path("find-pattern-alias-empty")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "a.cfg"), "a")
    File.write(File.join(dir, ".history"), "h")
    result = PluginSpecHelper.run("find", {"paths" => dir, "pattern" => ".authorized_keys"})

    result["matched"].as_i64.must_equal(0)
    paths_of(result).must_equal([] of String)
  end

  it "accepts the singular exclude= alias for excludes=" do
    dir = PluginSpecHelper.tmp_path("find-exclude-alias")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "a.cfg"), "a")
    File.write(File.join(dir, ".history"), "h")
    result = PluginSpecHelper.run("find", {"paths" => dir, "pattern" => "*", "exclude" => "a.cfg", "hidden" => "true"})

    paths_of(result).must_equal([File.join(dir, ".history")])
  end

  it "matches directories when file_type: directory" do
    result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "file_type" => "directory", "recurse" => "true"})

    paths_of(result).must_equal([File.join(tmp_dir, "sub"), File.join(tmp_dir, "sub", "subsub")].sort)
  end

  it "limits recursion depth when depth is set" do
    result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "*.txt", "recurse" => "true", "depth" => "1"})

    paths_of(result).must_equal([File.join(tmp_dir, "a.txt")])
  end

  it "reports a skipped path for a nonexistent search directory" do
    missing = File.join(tmp_dir, "does-not-exist")
    result = PluginSpecHelper.run("find", {"paths" => missing})

    result["matched"].as_i64.must_equal(0)
    result["skipped_paths"].as_h.has_key?(missing).must_equal(true)
  end

  it "warns and records an entry whose lstat fails instead of dropping it silently" do
    # Real find lstats every walked entry before any filtering and turns
    # a failing lstat into a per-entry skip: the entry is dropped,
    # recorded in skipped_paths under its own path with the OSError
    # str() text, warned about ("Skipped entry '<path>' due to access
    # issue: <errno text>") and the result msg flips to "Not all paths
    # examined, check warnings for details" - live-verified vs 2.19.11
    # with a read-but-no-execute directory (the same surface
    # claranet.log4shell's recursive scan of / trips on via vanishing
    # /proc/<pid>/fd/* symlinks). krikri previously swallowed the
    # failure with no warning and msg unchanged. Needs a non-root
    # runner: root stats through missing +x regardless.
    skip "running as root: the mode bits do not deny the search" if PluginSpecHelper.running_as_root?

    dir = PluginSpecHelper.tmp_path("find-lstat-failure")
    Dir.mkdir_p(dir)
    entry = File.join(dir, "f")
    File.write(entry, "f")
    File.chmod(dir, 0o644)

    result = PluginSpecHelper.run("find", {"paths" => dir})

    result["matched"].as_i64.must_equal(0)
    result["examined"].as_i64.must_equal(1)
    result["msg"].as_s.must_equal("Not all paths examined, check warnings for details")
    result["skipped_paths"].as_h[entry].as_s.must_equal("[Errno 13] Permission denied: '#{entry}'")
    result["warnings"].as_a.map(&.as_s).must_equal([
      "Skipped entry '#{entry}' due to access issue: [Errno 13] Permission denied: '#{entry}'",
    ])
  end

  it "fails with a clear message when paths is missing" do
    result = PluginSpecHelper.run("find", {} of String => String)

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("paths")
  end

  it "never reports changed" do
    result = PluginSpecHelper.run("find", {"paths" => tmp_dir})

    result["changed"].as_bool.must_equal(false)
  end

  describe "age" do
    it "matches files at least the given age (positive)" do
      old_path = File.join(tmp_dir, "old.age")
      File.write(old_path, "x")
      File.utime(Time.utc - 2.days, Time.utc - 2.days, old_path)

      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "*.age", "age" => "1d"})

      paths_of(result).must_equal([old_path])
    end

    it "matches files at most the given age (negative)" do
      new_path = File.join(tmp_dir, "new.age")
      File.write(new_path, "x")

      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "new.age", "age" => "-1d"})

      paths_of(result).must_equal([new_path])
    end

    it "compares against age_stamp: ctime/atime instead of the mtime default" do
      path = File.join(tmp_dir, "stamped.age")
      File.write(path, "x")
      # ctime can't be set directly, but a file this fresh should always
      # be well under 1 day old by any of the three timestamps.
      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "stamped.age", "age" => "1d", "age_stamp" => "ctime"})

      paths_of(result).must_equal([] of String)
    end
  end

  describe "contains" do
    it "matches a file whose content matches the regex, line-anchored by default" do
      path = File.join(tmp_dir, "needle-start.contains")
      File.write(path, "needle at line start\n")

      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "needle-start.contains", "contains" => "needle"})

      paths_of(result).must_equal([path])
    end

    it "does not match when the pattern is present but not at the start of any line" do
      path = File.join(tmp_dir, "needle-mid.contains")
      File.write(path, "prefix needle-not-at-start\n")

      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "needle-mid.contains", "contains" => "needle"})

      paths_of(result).must_equal([] of String)
    end

    it "matches mid-line content when read_whole_file: true" do
      path = File.join(tmp_dir, "needle-mid2.contains")
      File.write(path, "prefix needle-not-at-start\n")

      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "needle-mid2.contains", "contains" => "needle", "read_whole_file" => "true"})

      paths_of(result).must_equal([path])
    end

    it "excludes files whose content doesn't match" do
      path = File.join(tmp_dir, "no-match.contains")
      File.write(path, "nothing relevant here\n")

      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "no-match.contains", "contains" => "needle"})

      paths_of(result).must_equal([] of String)
    end

    it "is ignored when file_type is not file (contains only applies to regular files)" do
      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "file_type" => "directory", "contains" => "needle"})

      paths_of(result).wont_be_empty
    end
  end

  describe "mode: / exact_mode:" do
    # Real bug found via a proactive scope-cut audit: mode:/exact_mode:
    # were entirely unimplemented. Verified end-to-end against
    # ansible-playbook against the exact same fixture shape (0644/0755/
    # 0600) before writing these - see PluginHelpers::FindModeFilter's
    # own spec for the underlying logic's unit coverage.
    it "matches only files with the exact mode when exact_mode: true (the default)" do
      exact_dir = File.join(tmp_dir, "modes-exact")
      Dir.mkdir_p(exact_dir)
      a = File.join(exact_dir, "a.txt")
      b = File.join(exact_dir, "b.txt")
      File.write(a, "a")
      File.write(b, "b")
      File.chmod(a, 0o644)
      File.chmod(b, 0o755)

      result = PluginSpecHelper.run("find", {"paths" => exact_dir, "mode" => "0644"})

      paths_of(result).must_equal([a])
    end

    it "matches any file with at least one requested bit set when exact_mode: false" do
      loose_dir = File.join(tmp_dir, "modes-loose")
      Dir.mkdir_p(loose_dir)
      readable = File.join(loose_dir, "readable.txt")
      private_file = File.join(loose_dir, "private.txt")
      File.write(readable, "a")
      File.write(private_file, "b")
      File.chmod(readable, 0o644)
      File.chmod(private_file, 0o600)

      result = PluginSpecHelper.run("find", {"paths" => loose_dir, "mode" => "044", "exact_mode" => "false"})

      paths_of(result).must_equal([readable])
    end

    it "supports the symbolic u=,g=,o= assignment form" do
      symbolic_dir = File.join(tmp_dir, "modes-symbolic")
      Dir.mkdir_p(symbolic_dir)
      match = File.join(symbolic_dir, "match.txt")
      File.write(match, "a")
      File.chmod(match, 0o644)

      result = PluginSpecHelper.run("find", {"paths" => symbolic_dir, "mode" => "u=rw,g=r,o=r"})

      paths_of(result).must_equal([match])
    end
  end

  describe "limit:" do
    it "stops after finding the requested number of matches" do
      limit_dir = File.join(tmp_dir, "limit-test")
      Dir.mkdir_p(limit_dir)
      3.times { |i| File.write(File.join(limit_dir, "f#{i}.txt"), "x") }

      result = PluginSpecHelper.run("find", {"paths" => limit_dir, "patterns" => "*.txt", "limit" => "2"})

      result["matched"].as_i64.must_equal(2)
    end

    it "returns every match when limit: exceeds the real count" do
      limit_dir = File.join(tmp_dir, "limit-test-under")
      Dir.mkdir_p(limit_dir)
      2.times { |i| File.write(File.join(limit_dir, "f#{i}.txt"), "x") }

      result = PluginSpecHelper.run("find", {"paths" => limit_dir, "patterns" => "*.txt", "limit" => "10"})

      result["matched"].as_i64.must_equal(2)
    end
  end

  it "accepts a paths: that rendered as a bracketed list-of-one string, not just a comma-separated string" do
    # Real bug found benchmarking robertdebock.unowned_files (round
    # 111): `paths: "{{ unowned_files_directories }}"` where the
    # variable is a real single-element list - this codebase's plugin
    # params are always plain strings, so a `{{ }}`-templated list
    # variable renders to its own bracketed text form
    # (`["/some/dir"]`) rather than the bare path. Naively splitting
    # that on "," treated the WHOLE bracketed text as one literal path
    # ("not a directory"), so the loop over matched files never
    # iterated at all. Same bug class as apt.cr/package.cr/dnf.cr's own
    # `parse_package_names`.
    result = PluginSpecHelper.run("find", {"paths" => %(["#{tmp_dir}"]), "patterns" => "*.txt"})

    paths_of(result).must_equal([File.join(tmp_dir, "a.txt")])
  end

  describe "follow:" do
    it "does not descend into symlinked directories by default" do
      link = with_follow_fixture

      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "*.txt", "recurse" => "true"})

      paths_of(result).wont_include(File.join(link, "t.txt"))
    end

    it "descends into symlinked directories when follow: true" do
      link = with_follow_fixture

      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "*.txt", "recurse" => "true", "follow" => "true"})

      paths_of(result).must_include(File.join(link, "t.txt"))
    end

    it "still classifies a symlink as link with follow: true (Ansible lstats every entry regardless of follow)" do
      link = with_follow_fixture

      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "follow_link", "file_type" => "link", "follow" => "true"})

      paths_of(result).must_equal([link])
    end

    it "does not reclassify a symlink-to-directory as directory even with follow: true" do
      link = with_follow_fixture

      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "follow_link", "file_type" => "directory", "recurse" => "true", "follow" => "true"})

      paths_of(result).wont_include(link)
    end
  end

  describe "encoding:" do
    it "decodes content with the given encoding for a contains: match" do
      # "café latin" encoded as latin-1: bytes 0xE9/0xEF, invalid as UTF-8.
      enc_path = File.join(tmp_dir, "latin1.enc")
      File.write(enc_path, "caf\xE9 lat\xEFn")

      result = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "*.enc", "contains" => "café", "encoding" => "latin-1"})

      paths_of(result).must_equal([enc_path])
    end

    it "abandons the whole search path when contains: hits an undecodable file" do
      # Real find.py opens contains: files as TEXT with open()'s default
      # codec (UTF-8, strict error handling); an undecodable byte raises
      # UnicodeDecodeError, which contentfilter re-raises as "Failed to
      # read the file <path> due to an encoding error. current encoding:
      # None (default determined by the Python built-in function
      # \"open\")" - the main loop then skips the WHOLE search path with
      # that reason, warns, and flips the msg. krikri previously read
      # such files as raw bytes and matched latin-1-style straight
      # through them, silently (issue #893: a git object file produced
      # real's stderr warning while krikri printed nothing).
      dir = PluginSpecHelper.tmp_path("find-decode-error")
      Dir.mkdir_p(dir)
      blob = File.join(dir, "blob.bin")
      File.write(blob, "\x78\x9c\x0a binary \xFF\xFE")

      result = PluginSpecHelper.run("find", {"paths" => dir, "contains" => "tree"})

      result["matched"].as_i64.must_equal(0)
      result["examined"].as_i64.must_equal(1)
      result["msg"].as_s.must_equal("Not all paths examined, check warnings for details")
      result["skipped_paths"].as_h[dir].as_s.must_equal(
        "Failed to read the file #{blob} due to an encoding error. " \
        "current encoding: None (default determined by the Python built-in function \"open\")"
      )
      result["warnings"].as_a.map(&.as_s).must_equal([
        "Skipped '#{dir}' path due to this access issue: " \
        "Failed to read the file #{blob} due to an encoding error. " \
        "current encoding: None (default determined by the Python built-in function \"open\")\n",
      ])
    end

    it "abandons the whole search path on an undecodable file with read_whole_file: true too" do
      # read_whole_file: true reads the entire file (f.read()) before
      # searching, so the first undecodable byte anywhere wins, match or
      # not.
      dir = PluginSpecHelper.tmp_path("find-decode-error-whole")
      Dir.mkdir_p(dir)
      blob = File.join(dir, "blob.bin")
      File.write(blob, "tree\n\xFF")

      result = PluginSpecHelper.run("find", {"paths" => dir, "contains" => "tree", "read_whole_file" => "true"})

      result["matched"].as_i64.must_equal(0)
      result["skipped_paths"].as_h[dir].as_s.must_equal(
        "Failed to read the file #{blob} due to an encoding error. " \
        "current encoding: None (default determined by the Python built-in function \"open\")"
      )
    end

    it "matches a line from a fully-decoded chunk before an undecodable byte in a later chunk" do
      # Real's TextIOWrapper decodes 8192-byte chunks and yields their
      # lines whole, so a "tree" line inside the first chunk is matched
      # before the second chunk - holding the undecodable bytes - is
      # ever decoded; the whole-file strict decode must not fire here.
      dir = PluginSpecHelper.tmp_path("find-decode-chunk-match")
      Dir.mkdir_p(dir)
      path = File.join(dir, "blob.chunk")
      File.write(path, "tree\n" + ("x" * 9000) + "\xFF\xFE")

      result = PluginSpecHelper.run("find", {"paths" => dir, "patterns" => "*.chunk", "contains" => "tree"})

      paths_of(result).must_equal([path])
      result["msg"].as_s.must_equal("All paths examined")
    end

    it "does not affect get_checksum - Ansible hashes raw bytes regardless of encoding" do
      bin_path = File.join(tmp_dir, "cksum.bin")
      File.write(bin_path, "\xFF\xFE data")
      expected = Digest::SHA1.hexdigest("\xFF\xFE data")

      without_encoding = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "cksum.bin", "get_checksum" => "true"})
      with_encoding = PluginSpecHelper.run("find", {"paths" => tmp_dir, "patterns" => "cksum.bin", "get_checksum" => "true", "encoding" => "latin-1"})

      without_encoding["files"][0]["checksum"].as_s.must_equal(expected)
      with_encoding["files"][0]["checksum"].as_s.must_equal(expected)
    end
  end
end
