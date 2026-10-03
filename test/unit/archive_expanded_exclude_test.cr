require "../minitest_helper"

# Pins plugins/archive.cr's expanded_exclude_paths result key (real
# community.general archive's result property carries it "returned:
# always", built from the same expand_paths pass as expanded_paths - a
# LIST of expanded exclude paths, including literal nonexistent ones,
# and [] when no exclude_path was given).

describe "archive expanded_exclude_paths" do
  it "lists the expanded exclude paths on a successful archive" do
    work = PluginSpecHelper.tmp_path("archive-xpaths")
    Dir.mkdir_p(File.join(work, "srcdir"))
    File.write(File.join(work, "srcdir", "a.txt"), "one\n")
    File.write(File.join(work, "srcdir", "b.txt"), "two\n")
    dest = File.join(work, "made.tar.gz")

    result = PluginSpecHelper.run("archive", {
      "path"         => File.join(work, "srcdir"),
      "dest"         => dest,
      "format"       => "gz",
      "exclude_path" => File.join(work, "srcdir", "b.txt"),
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["expanded_exclude_paths"].as_a.map(&.as_s).must_equal([File.join(work, "srcdir", "b.txt")])
  end

  it "carries an empty list when no exclude_path was given" do
    work = PluginSpecHelper.tmp_path("archive-xpaths-none")
    Dir.mkdir_p(File.join(work, "srcdir"))
    File.write(File.join(work, "srcdir", "a.txt"), "one\n")
    dest = File.join(work, "made.tar.gz")

    result = PluginSpecHelper.run("archive", {"path" => File.join(work, "srcdir"), "dest" => dest, "format" => "gz"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["expanded_exclude_paths"].as_a.size.must_equal(0)
  end

  it "keeps literal nonexistent exclude paths, like real's expand_paths" do
    work = PluginSpecHelper.tmp_path("archive-xpaths-missing")
    Dir.mkdir_p(File.join(work, "srcdir"))
    File.write(File.join(work, "srcdir", "a.txt"), "one\n")
    dest = File.join(work, "made.tar.gz")
    missing_exclude = File.join(work, "srcdir", "gone.txt")

    result = PluginSpecHelper.run("archive", {
      "path"         => File.join(work, "srcdir"),
      "dest"         => dest,
      "format"       => "gz",
      "exclude_path" => missing_exclude,
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["expanded_exclude_paths"].as_a.map(&.as_s).must_equal([missing_exclude])
  end

  it "carries the key on the dest_state: absent path too" do
    work = PluginSpecHelper.tmp_path("archive-xpaths-absent")
    missing_source = File.join(work, "nope.txt")
    dest = File.join(work, "made.tar.gz")

    result = PluginSpecHelper.run("archive", {"path" => missing_source, "dest" => dest, "format" => "gz"})

    result["dest_state"].as_s.must_equal("absent")
    result["expanded_exclude_paths"].as_a.size.must_equal(0)
  end
end
