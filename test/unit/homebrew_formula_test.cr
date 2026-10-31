require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)

# Formula/krikri.rb and Formula/krikri-multiarch.rb are the shipped
# install path for release binaries (the tap is this repo itself) and are
# maintained by hand - these specs pin the invariants that have already
# bitten users once: the two formulas must move versions together, and
# the macOS dependency lists must declare every Homebrew library the
# released Mach-O binaries actually link (a missing one only shows up as
# a dyld load failure on a machine that has none of the others - issue
# #680, where gmp/libyaml/xz were linked but undeclared).
describe "homebrew formulas" do
  FORMULAS = {
    "krikri"           => File.join(PROJECT_ROOT, "Formula", "krikri.rb"),
    "krikri-multiarch" => File.join(PROJECT_ROOT, "Formula", "krikri-multiarch.rb"),
  }

  it "pin the same release version in both formulas" do
    versions = FORMULAS.values.map do |path|
      line = File.read_lines(path).find { |file_line| file_line.strip.starts_with?("version ") }
      line.to_s.strip
    end
    versions.uniq.size.must_equal(1, "formulas disagree on version: #{versions.uniq}")
  end

  it "declare every Homebrew library the macOS binaries link" do
    # Verified against the release binaries' Mach-O load commands: the
    # main binaries link gmp and libyaml at their Homebrew paths and the
    # plugin binaries also link xz's liblzma, beyond the three the
    # formulas originally listed (openssl@3, pcre2, bdw-gc).
    required = %w[openssl@3 pcre2 bdw-gc gmp libyaml xz]
    FORMULAS.each do |name, path|
      content = File.read(path)
      declared = required.select { |dep| content.includes?("depends_on \"#{dep}\"") }
      missing = required - declared
      missing.empty?.must_equal(true, "#{name} is missing macOS deps: #{missing}")
    end
  end

  it "install the Linux plugin sets a Mac controller needs for Linux targets" do
    # plugin_manager looks up cross-OS targets as plugins-<os>-<arch>/
    # next to the executable, so the multiarch formula must land both
    # Linux plugin sets (and the other Mac CPU's set, renamed to
    # plugins-<other>) in the Cellar bin/.
    content = File.read(FORMULAS["krikri-multiarch"])
    # Homebrew strips a tarball's single top-level directory during
    # staging, so the install block references the bundle's inner paths
    # directly (same reason Formula/krikri.rb does not prefix with the
    # tarball's own wrapper dir).
    [
      "bin.install \"\#{arch}/krikri-playbook\"",
      "bin.install \"\#{arch}/plugins\"",
      "bin.install \"plugins-linux-x86_64\"",
      "bin.install \"plugins-linux-aarch64\"",
      "bin.install \"darwin-\#{other}/plugins\" => \"plugins-\#{other}\"",
    ].each do |piece|
      content.includes?(piece).must_equal(true, "multiarch formula does not install #{piece}")
    end
  end
end
