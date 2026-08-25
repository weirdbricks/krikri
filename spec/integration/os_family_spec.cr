require "../spec_helper"

# ansible_os_family for a DERIVATIVE distro. On LMDE 7 (ID=linuxmint,
# ID_LIKE=debian) real Ansible reports "Debian" while this engine
# reported "Linux" - so every `when: ansible_os_family == "Debian"` gate
# in every role silently skipped, and an OS-keyed
# `vars-{{ ansible_os_family }}.yml` pointed at a file that does not
# exist. The benchmark hosts have always been plain Ubuntu/Rocky, which
# is why no round ever caught it.
#
# Runs the real compiled facts plugin rather than a copy of its mapping
# table, and derives what to expect from this machine's own
# /etc/os-release, so it stays honest wherever it runs.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private FACTS_PLUGIN = File.join(PROJECT_ROOT, "bin", "plugins", "facts")

private def os_release : Hash(String, String)
  return {} of String => String unless File.exists?("/etc/os-release")

  File.read_lines("/etc/os-release").compact_map do |line|
    key, _, value = line.partition('=')
    next if value.empty?
    {key.strip, value.strip.strip('"')}
  end.to_h
end

private def gathered_facts : Hash(String, JSON::Any)
  stdout_io = IO::Memory.new
  Process.run(FACTS_PLUGIN, [] of String,
    input: IO::Memory.new("{}"), output: stdout_io, error: Process::Redirect::Close)
  parsed = JSON.parse(stdout_io.to_s)
  parsed["ansible_facts"]?.try(&.as_h?) || parsed.as_h
rescue
  {} of String => JSON::Any
end

describe "ansible_os_family" do
  it "reports a real family rather than falling back to 'Linux'" do
    pending! "facts plugin not built (run ./build.sh)" unless File.exists?(FACTS_PLUGIN)

    release = os_release
    pending! "no /etc/os-release to derive an expectation from" if release.empty?

    # Only meaningful when this machine IS a known distro or declares a
    # parent via ID_LIKE - which is exactly the derivative case that used
    # to fall through to "Linux".
    id = release["ID"]?
    id_like = release["ID_LIKE"]?
    pending! "distro declares neither ID nor ID_LIKE" unless id || id_like

    facts = gathered_facts
    family = facts["ansible_os_family"]?.try(&.as_s?)
    pending! "facts plugin produced no ansible_os_family" unless family

    family.should_not eq("Linux")

    if (like = id_like) && like.split(/\s+/).includes?("debian")
      family.should eq("Debian")
    end
  end
end
