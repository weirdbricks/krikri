require "../minitest_helper"
require "../../src/krikri/version"

# `--version` now lists every runtime shard with its pinned version,
# matching real `ansible --version`'s dependency stack (python/jinja/
# pyyaml lines). The list is baked in at compile time from shard.lock,
# so these specs exercise the parsing/formatting logic plus the baked
# constant itself.

describe "Krikri.parse_shard_lock_versions" do
  it "extracts shard names and versions from a lock-file-shaped string" do
    lock = <<-LOCK
      version: 2.0
      shards:
        ameba:
          git: https://github.com/crystal-ameba/ameba.git
          version: 1.6.4

        crinja:
          git: https://github.com/weirdbricks/crinja.git
          version: 0.9.0+git.commit.3d6923966141a9f6d6e3eb95ca9f426e529e427c

        pg:
          git: https://github.com/will/crystal-pg.git
          version: 0.30.0
      LOCK

    versions = Krikri.parse_shard_lock_versions(lock)
    versions["ameba"].must_equal("1.6.4")
    versions["crinja"].must_equal("0.9.0+git.commit.3d6923966141a9f6d6e3eb95ca9f426e529e427c")
    versions["pg"].must_equal("0.30.0")
    versions.size.must_equal(3)
  end

  it "ignores the lock file's own top-level format version" do
    lock = "version: 2.0\nshards:\n  pg:\n    version: 0.30.0\n"
    Krikri.parse_shard_lock_versions(lock).must_equal({"pg" => "0.30.0"})
  end

  it "returns an empty hash when there is no shards section" do
    Krikri.parse_shard_lock_versions("").must_equal({} of String => String)
  end
end

describe "Krikri.parse_shard_yml_section_names" do
  it "lists the names under a requested top-level section only" do
    yml = <<-YML
      name: krikri
      version: 0.9.90

      description: |
        Some text with a colon: like this

      dependencies:
        crinja:
          github: weirdbricks/crinja
        pg:
          github: will/crystal-pg

      development_dependencies:
        ameba:
          github: crystal-ameba/ameba

      crystal: ">= 1.0.0"
      YML

    Krikri.parse_shard_yml_section_names(yml, "development_dependencies")
      .must_equal(["ameba"])
    Krikri.parse_shard_yml_section_names(yml, "dependencies")
      .must_equal(["crinja", "pg"])
    Krikri.parse_shard_yml_section_names(yml, "nonexistent").must_be_empty
  end
end

describe "Krikri.semantic_shard_version" do
  it "strips the git-commit suffix down to the semantic version" do
    Krikri.semantic_shard_version("0.9.0+git.commit.3d6923966141a9f6d6e3eb95ca9f426e529e427c")
      .must_equal("0.9.0")
    Krikri.semantic_shard_version("0.30.0").must_equal("0.30.0")
  end
end

describe Krikri::RUNTIME_DEPENDENCY_VERSIONS do
  it "matches shard.lock, minus development-only shards, with semantic versions" do
    lock_text = File.read(File.join(__DIR__, "..", "..", "shard.lock"))
    yml_text = File.read(File.join(__DIR__, "..", "..", "shard.yml"))
    dev_names = Krikri.parse_shard_yml_section_names(yml_text, "development_dependencies")

    expected = Krikri.parse_shard_lock_versions(lock_text)
      .reject { |name, _| dev_names.includes?(name) }
      .map { |name, version| {name, Krikri.semantic_shard_version(version)} }
      .sort_by! { |entry| entry[0] }

    Krikri::RUNTIME_DEPENDENCY_VERSIONS.must_equal(expected)
  end

  it "excludes ameba (the only dev dependency today)" do
    names = Krikri::RUNTIME_DEPENDENCY_VERSIONS.map { |entry| entry[0] }
    names.wont_include("ameba")
    names.must_include("krikri-jinja")
  end
end

describe "Krikri.parse_shard_yml_dependency_pins" do
  it "extracts github/tag/branch/commit per dependency, nil for unpinned fields" do
    yml = <<-YML
      name: krikri
      version: 0.9.90

      dependencies:
        crinja:
          github: weirdbricks/crinja
          tag: crystal-play-0.9.32
        docr:
          github: weirdbricks/docr
          commit: c90ea8d6a0c5eb9f842ac0da098a1718ecca66ca
        legacy:
          github: weirdbricks/legacy
          branch: master
        bz2:
          github: weirdbricks/bz2.cr
        pg:
          github: will/crystal-pg

      development_dependencies:
        ameba:
          github: crystal-ameba/ameba

      crystal: ">= 1.0.0"
      YML

    pins = Krikri.parse_shard_yml_dependency_pins(yml, "dependencies")
    pins.must_equal({
      "crinja" => {github: "weirdbricks/crinja", tag: "crystal-play-0.9.32", branch: nil, commit: nil},
      "docr"   => {github: "weirdbricks/docr", tag: nil, branch: nil, commit: "c90ea8d6a0c5eb9f842ac0da098a1718ecca66ca"},
      "legacy" => {github: "weirdbricks/legacy", tag: nil, branch: "master", commit: nil},
      "bz2"    => {github: "weirdbricks/bz2.cr", tag: nil, branch: nil, commit: nil},
      "pg"     => {github: "will/crystal-pg", tag: nil, branch: nil, commit: nil},
    })
  end

  it "returns an empty hash when the section is missing or has no entries" do
    Krikri.parse_shard_yml_dependency_pins("name: krikri\n", "dependencies")
      .must_equal({} of String => Krikri::ShardYmlPin)
    Krikri.parse_shard_yml_dependency_pins("dependencies:\ncrystal: \">= 1.0.0\"\n", "dependencies")
      .must_equal({} of String => Krikri::ShardYmlPin)
  end
end

describe "Krikri::RUNTIME_DEPENDENCY_FORK_NOTES" do
  it "annotates only weirdbricks-owned dependencies, with their pin" do
    notes = Krikri::RUNTIME_DEPENDENCY_FORK_NOTES

    expect(str_starts_with?(notes["krikri-jinja"], " (weirdbricks/krikri-jinja fork, tag v")).must_equal(true)
    notes["mysql"].must_equal(" (weirdbricks/crystal-mysql fork, tag crystal-ansible-0.9.340)")
    notes["docr"].must_equal(" (weirdbricks/docr fork, commit c90ea8d)")
    notes["awscr-signer"].must_equal(" (weirdbricks/awscr-signer fork, commit 2a8cc09)")
    notes["bz2"].must_equal(" (weirdbricks/bz2.cr fork)")

    notes.has_key?("pg").must_equal(false)
    notes.has_key?("crystar").must_equal(false)
    notes.has_key?("xz").must_equal(false)
    notes.has_key?("db").must_equal(false)
  end
end

describe Krikri.version_info do
  it "prints the Crystal version and one labeled line per runtime shard" do
    info = Krikri.version_info
    info.must_include("Crystal: #{Crystal::VERSION}")
    info.must_include("Shards:")
    Krikri::RUNTIME_DEPENDENCY_VERSIONS.each do |(name, version)|
      info.must_include("  #{name}: #{version}")
    end
  end

  it "appends a fork annotation to weirdbricks-owned shards, plain version otherwise" do
    info = Krikri.version_info
    Krikri::RUNTIME_DEPENDENCY_VERSIONS.each do |(name, version)|
      note = Krikri::RUNTIME_DEPENDENCY_FORK_NOTES[name]? || ""
      info.must_include("  #{name}: #{version}#{note}")
    end
    info.must_include("pg: 0.30.0\n")
    info.wont_match(/pg: [^\n]*fork/)
  end
end
