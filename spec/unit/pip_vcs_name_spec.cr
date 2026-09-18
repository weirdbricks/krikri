require "../spec_helper"

# Regression spec for pip's VCS-requirement idempotency pre-check, found
# via grycap.clues (rounds 700036/820004): the plugin's changed-detection
# pre-check derives a distribution name and runs `pip show <name>`, but a
# VCS requirement (`git+https://github.com/grycap/clues.git@master`)
# reached `pip show` verbatim - which always fails - so every rerun of a
# `pip: {name: git+...}` task re-installed and reported `changed: true`
# where real Ansible's own pip module pre-checks by the DERIVED package
# name and reports ok. Real pip.py derives the name from the `#egg=`
# fragment or the URL basename (.git stripped); `.../clues.git@master`
# -> "clues".
#
# Driven through the real plugin binary via PluginSpecHelper with a fake
# pip executable so the spec is hermetic: no real pip, no network, no
# mutation of the dev machine's python environment. The fake pip records
# its `show` argument so the spec can assert the DERIVED name was used.
describe "pip: VCS requirement idempotency pre-check" do
  it "derives the bare distribution name from a git+ URL (not the raw URL)" do
    with_fake_vcs_pip_installed("clues") do |script, recorded|
      result = PluginSpecHelper.run("pip", {
        "name"       => "git+https://github.com/grycap/clues.git@master",
        "executable" => script,
      })

      (result["failed"]?.try(&.as_bool) || false).should be_false
      result["changed"].as_bool.should be_false
      result["msg"].as_s.should contain("already installed")
      File.read(recorded).chomp.should eq("clues")
    end
  end

  it "prefers the #egg= fragment over the URL basename" do
    with_fake_vcs_pip_installed("eggname") do |script, recorded|
      result = PluginSpecHelper.run("pip", {
        "name"       => "git+https://example.com/some/repo.git@v1#egg=eggname",
        "executable" => script,
      })

      (result["failed"]?.try(&.as_bool) || false).should be_false
      result["changed"].as_bool.should be_false
      File.read(recorded).chomp.should eq("eggname")
    end
  end
end

# Fake pip: `show <name>` exits 0 (package installed) and records the
# queried name; `install ...` would mean the pre-check failed to derive
# the name, so it exits 1 with a loud marker. Writes every `show` target
# to a file the spec asserts against.
private def with_fake_vcs_pip_installed(expected_name : String, &)
  dir = File.join(Dir.tempdir, "krikri-pip-vcs-spec-#{Process.pid}-#{rand(100000)}")
  Dir.mkdir(dir)
  script = File.join(dir, "fakepip")
  recorded = File.join(dir, "show-args")
  body = %(#!/bin/sh\nif [ "$1" = "show" ]; then echo "$2" >> #{Process.quote(recorded)}; if [ "$2" = #{Process.quote(expected_name)} ]; then echo "Name: #{expected_name}\\nVersion: 1.0"; exit 0; else echo "WARNING: Package(s) not found: $2" >&2; exit 1; fi; fi\nif [ "$1" = "install" ]; then echo "PRE-CHECK FAILED TO DERIVE NAME" >&2; exit 1; fi\nexit 0\n)
  File.write(script, body)
  File.chmod(script, 0o755)
  begin
    yield script, recorded
  ensure
    File.delete(script)
    File.delete(recorded) if File.exists?(recorded)
    Dir.delete(dir)
  end
end
