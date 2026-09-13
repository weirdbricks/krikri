require "yaml"

module Krikri
  VERSION = "0.9.1032"

  # Baked into the binary at compile time (never read from disk at
  # runtime - a deployed binary has no shard.lock beside it), the same
  # way real `ansible --version` reports the exact jinja/pyyaml/python
  # versions it is actually running with.
  private SHARD_LOCK_TEXT = {{ read_file("#{__DIR__}/../../shard.lock") }}
  private SHARD_YML_TEXT  = {{ read_file("#{__DIR__}/../../shard.yml") }}

  # Parses a shard.lock's `shards:` section into {name => version}.
  # Line-based rather than YAML-lib based so it stays a pure, fixture-
  # testable function; the lock file's own emitted shape (2-space shard
  # names, 4-space keys) is stable across shards versions.
  def self.parse_shard_lock_versions(content : String) : Hash(String, String)
    versions = {} of String => String
    current : String? = nil
    content.each_line do |line|
      if name_match = line.match(/^  ([^\s:]+):\s*$/)
        current = name_match[1]
      elsif version_match = line.match(/^    version:\s*(\S+)\s*$/)
        versions[current.to_s] = version_match[1] if current
      end
    end
    versions
  end

  # Extracts the shard names listed under a top-level section header
  # (e.g. "dependencies:" / "development_dependencies:") of a shard.yml.
  def self.parse_shard_yml_section_names(content : String, section : String) : Array(String)
    names = [] of String
    in_section = false
    content.each_line do |line|
      if header_match = line.match(/^([^\s#].*?):\s*$/)
        in_section = header_match[1] == section
      elsif name_match = line.match(/^  ([^\s:]+):\s*$/)
        names << name_match[1] if in_section
      end
    end
    names
  end

  # "0.9.0+git.commit.<sha>" -> "0.9.0" - the semantic version a user
  # comparing "what version of X am I running" actually wants, matching
  # how pip reports jinja2/pyyaml in real `ansible --version`.
  def self.semantic_shard_version(version : String) : String
    version.split('+').first
  end

  # Runtime dependency list (dev-only shards like ameba filtered out by
  # category, not by name), sorted for a stable, diffable listing.
  RUNTIME_DEPENDENCY_VERSIONS = begin
    dev_names = parse_shard_yml_section_names(SHARD_YML_TEXT, "development_dependencies")
    parse_shard_lock_versions(SHARD_LOCK_TEXT)
      .reject { |name, _| dev_names.includes?(name) }
      .map { |name, version| {name, semantic_shard_version(version)} }
      .sort_by! { |entry| entry[0] }
  end

  def self.version_info : String
    lines = [
      "krikri #{VERSION}",
      "Fast, Ansible-compatible automation tool written in Crystal",
      "",
      "Crystal: #{Crystal::VERSION}",
      "Shards:",
    ]
    RUNTIME_DEPENDENCY_VERSIONS.each do |(name, version)|
      lines << "  #{name}: #{version}"
    end
    lines.join("\n")
  end

  def self.banner : String
    String.build do |str|
      str << "KRIKRI v#{VERSION}"
    end
  end
end
