require "yaml"

module Krikri
  VERSION = "0.9.1307"

  # Baked in at compile time via the same `--release` flag `build.sh`
  # passes through to `crystal build`. A timing-sensitive round run
  # against a debug binary is ~1.8x slower wall-clock than release on
  # identical work (measured on dev-sec os_hardening) - this lets
  # krikri-role-tester warn when a round launches on one, instead of
  # silently publishing inflated per-role timings.
  BUILD_FLAVOR = {{ flag?(:release) ? "release" : "debug" }}

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

  # Pin info per dependency under a top-level section header (e.g.
  # "dependencies:") of a shard.yml: {name => {github, tag, branch, commit}}
  # with nil for whatever the entry doesn't pin. Line-based like the parsers
  # above so it stays a pure, fixture-testable function.
  alias ShardYmlPin = {github: String?, tag: String?, branch: String?, commit: String?}

  def self.parse_shard_yml_dependency_pins(content : String, section : String) : Hash(String, ShardYmlPin)
    pins = {} of String => ShardYmlPin
    in_section = false
    current : String? = nil
    content.each_line do |line|
      if header_match = line.match(/^([^\s#].*?):\s*$/)
        in_section = header_match[1] == section
        current = nil
      elsif name_match = line.match(/^  ([^\s:]+):\s*$/)
        current = name_match[1]
        pins[current] = {github: nil, tag: nil, branch: nil, commit: nil} if in_section
      elsif field_match = line.match(/^    (github|tag|branch|commit):\s*(\S.*?)\s*$/)
        if in_section && (cur = current) && (existing = pins[cur]?)
          pins[cur] = update_pin_field(existing, field_match[1], field_match[2])
        end
      end
    end
    pins
  end

  private def self.update_pin_field(pin : ShardYmlPin, field : String, value : String) : ShardYmlPin
    case field
    when "github" then {github: value, tag: pin[:tag], branch: pin[:branch], commit: pin[:commit]}
    when "tag"    then {github: pin[:github], tag: value, branch: pin[:branch], commit: pin[:commit]}
    when "commit" then {github: pin[:github], tag: pin[:tag], branch: pin[:branch], commit: value}
    else               {github: pin[:github], tag: pin[:tag], branch: value, commit: pin[:commit]}
    end
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

  # Fork annotation per runtime dependency, keyed by shard name. Several
  # of the shards krikri ships are its own patched forks of upstream
  # libraries (identified by the weirdbricks GitHub owner in shard.yml,
  # which carries real behavioral changes, not just version pins); a
  # deployed binary should say which repo it was actually built from.
  RUNTIME_DEPENDENCY_FORK_NOTES = begin
    notes = {} of String => String
    parse_shard_yml_dependency_pins(SHARD_YML_TEXT, "dependencies").each do |name, pin|
      next unless (github = pin[:github]) && github.starts_with?("weirdbricks/")
      suffix = ""
      if tag = pin[:tag]
        suffix = ", tag #{tag}"
      elsif branch = pin[:branch]
        suffix = ", branch #{branch}"
      elsif commit = pin[:commit]
        suffix = ", commit #{commit[0, 7]}"
      end
      notes[name] = " (#{github} fork#{suffix})"
    end
    notes
  end

  def self.version_info : String
    version_info("krikri", VERSION,
      "Fast, Ansible-compatible automation tool written in Crystal")
  end

  # Shared --version shape for every krikri binary (playbook, ad-hoc
  # CLI, lint): tool name/version, tagline, then the exact Crystal and
  # shard versions compiled in.
  def self.version_info(name : String, version : String, tagline : String) : String
    lines = [
      "#{name} #{version}",
      tagline,
      "",
      "Build: #{BUILD_FLAVOR}",
      "Crystal: #{Crystal::VERSION}",
      "Shards:",
    ]
    RUNTIME_DEPENDENCY_VERSIONS.each do |(dep, dep_version)|
      lines << "  #{dep}: #{dep_version}#{RUNTIME_DEPENDENCY_FORK_NOTES[dep]? || ""}"
    end
    lines.join("\n")
  end

  def self.banner : String
    String.build do |str|
      str << "KRIKRI v#{VERSION}"
    end
  end
end
