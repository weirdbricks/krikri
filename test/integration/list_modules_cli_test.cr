require "../minitest_helper"

# krikri-playbook --list-modules is the machine-readable view of the
# supported-module registry: krikri-playbook-generator derives its fuzzing
# scope from it (`kpg modules --scope-from-krikri`), so a module the engine
# implements but the listing omits would silently drop out of coverage.
# JSON, sorted, unique - a caller consumes it directly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

raise "bin/krikri-playbook missing - run ./build.sh first" unless File.exists?(BINARY)

private def list_modules : Array(String)
  output = IO::Memory.new
  status = Process.run(BINARY, ["--list-modules"], output: output, error: output, chdir: PROJECT_ROOT)
  status.success?.must_equal(true, "krikri-playbook --list-modules exited #{status.exit_code}: #{output.to_s}")
  Array(String).from_json(output.to_s)
end

describe "krikri-playbook --list-modules" do
  it "prints the registry as a JSON array of FQCNs" do
    modules = list_modules

    refute_empty modules
    modules.must_equal modules.uniq, "the listing must not repeat a module"
    modules.must_equal modules.sort, "the listing must be sorted"
    modules.each { |name| name.must_match(/\A(?:[a-z0-9_]+\.[a-z0-9_]+\.)?[a-z0-9_]+\z/) }
  end

  it "includes the core modules and the collection modules the engine implements" do
    modules = list_modules

    modules.must_include "ansible.builtin.copy"
    modules.must_include "ansible.builtin.dnf"
    modules.must_include "ansible.posix.synchronize"
    modules.must_include "community.general.ini_file"
    modules.must_include "community.crypto.x509_certificate"
  end

  it "prints nothing but the JSON array, so a caller can parse stdout directly" do
    output = IO::Memory.new
    Process.run(BINARY, ["--list-modules"], output: output, chdir: PROJECT_ROOT)
    Array(String).from_json(output.to_s)
    output.to_s.lines.size.must_equal 1
  end
end
