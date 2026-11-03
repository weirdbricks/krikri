require "../minitest_helper"
require "file_utils"
require "../../src/krikri/python_lookup_runner"

# Issue #778: the controller-side wrapper mechanisms spawn the first
# `python3`/`python` on PATH and give up when that interpreter cannot
# import the `ansible` package - which every caller silently degrades to
# its pre-custom-plugin behavior (a lookup()/query() of a plugin that
# DOES exist becomes `null`). On a controller whose ansible lives in its
# own venv (pipx, Homebrew - `ansible-playbook`'s shebang names it)
# while `python3` on PATH has no `ansible` package, real
# ansible-playbook runs the plugin and krikri returned null.
#
# So a wrapper answer of kind "unavailable" is retried once under the
# interpreter `ansible-playbook` itself runs under. These specs cover
# both halves: reading that shebang, and a full dispatch that survives a
# useless `python3` because of it.
private def ansible_importable_on(python : String) : Bool
  Process.run(python, ["-c", Krikri::ControllerPython::PROBE],
    input: Process::Redirect::Close, output: Process::Redirect::Close,
    error: Process::Redirect::Close).success?
end

private def usable_python3 : String?
  python = Krikri::ControllerPython.executable
  return nil unless python
  return nil unless ansible_importable_on(python)
  python
end

# A `python3` that answers every wrapper request with "the ansible
# package is not importable" (issue #778's degenerate controller) but
# fails the capability probe, so it is never picked FOR the retry.
private def write_unusable_python3(bin : String) : String
  Dir.mkdir_p(bin)
  path = File.join(bin, "python3")
  File.write(path, <<-SH)
    #!/bin/sh
    if [ "$1" = "-c" ] && [ "$2" = "#{Krikri::ControllerPython::PROBE}" ]; then exit 1; fi
    printf '%s\\n' '{"ok": false, "kind": "unavailable", "error": "no ansible here"}'
    SH
  File.chmod(path, 0o755)
  path
end

# An executable `ansible-playbook` whose shebang names *python* - the
# only part of it `ansible_capable` reads.
private def write_ansible_playbook(bin : String, shebang : String) : String
  Dir.mkdir_p(bin)
  path = File.join(bin, "ansible-playbook")
  File.write(path, "#!#{shebang}\nraise SystemExit(0)\n")
  File.chmod(path, 0o755)
  path
end

private def with_path(bin : String, &)
  previous = ENV["PATH"]
  ENV["PATH"] = "#{bin}:#{previous}"
  begin
    yield
  ensure
    ENV["PATH"] = previous
  end
end

describe Krikri::ControllerPython do
  exclusive! # ENV["PATH"] is process-wide

  it "reads the interpreter ansible-playbook runs under out of its shebang" do
    python = usable_python3
    return unless python

    bin = PluginSpecHelper.tmp_path("controller-python-shebang")
    fake = write_unusable_python3(bin)
    write_ansible_playbook(bin, python)
    with_path(bin) do
      # the plain PATH python3 is the unusable one...
      Krikri::ControllerPython.executable.must_equal(fake)
      # ...and the shebang names the interpreter the retry must use
      Krikri::ControllerPython.ansible_capable(fake).must_equal(python)
    end
    FileUtils.rm_r(bin)
  end

  it "resolves a #!/usr/bin/env python3 shebang through PATH" do
    python = usable_python3
    return unless python

    bin = PluginSpecHelper.tmp_path("controller-python-env-shebang")
    FileUtils.mkdir_p(bin)
    # a CAPABLE python3 in the shim dir (a symlink to the real one), named
    # so an `env python3` shebang resolves to it
    Dir.mkdir_p(bin)
    File.symlink(python, File.join(bin, "python3"))
    write_ansible_playbook(bin, "/usr/bin/env python3")
    with_path(bin) do
      Krikri::ControllerPython.ansible_capable(nil).must_equal(File.join(bin, "python3"))
    end
    FileUtils.rm_r(bin)
  end

  it "retries an unavailable wrapper under the ansible-playbook interpreter (issue #778)" do
    python = usable_python3
    return unless python

    root = PluginSpecHelper.tmp_path("controller-python-retry")
    bin = File.join(root, "bin")
    Dir.mkdir_p(bin)
    write_unusable_python3(bin)
    write_ansible_playbook(bin, python)

    plugin_dir = File.join(root, "lookup_plugins")
    Dir.mkdir_p(plugin_dir)
    source = File.join(plugin_dir, "mylist.py")
    File.write(source, <<-PYTHON)
      from ansible.plugins.lookup import LookupBase

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return ["alpha", "beta"]
      PYTHON

    empty = {} of String => JSON::Any
    with_path(bin) do
      result = Krikri::PythonLookupRunner.call_lookup("mylist", source,
        [] of JSON::Any, empty, empty)
      result.as_a.map(&.as_s).must_equal(["alpha", "beta"])
    end
    FileUtils.rm_r(root)
  end

  it "keeps the unavailable verdict when no interpreter can import ansible" do
    bin = PluginSpecHelper.tmp_path("controller-python-none")
    Dir.mkdir_p(bin)
    fake = write_unusable_python3(bin)
    # an ansible-playbook whose shebang python is that same unusable one,
    # and a PATH holding nothing else that could be probed
    write_ansible_playbook(bin, fake)
    previous = ENV["PATH"]
    ENV["PATH"] = bin
    begin
      Krikri::ControllerPython.ansible_capable(fake).must_be_nil
      ex = assert_raises(Krikri::PythonLookupRunner::LookupUnavailableError) do
        Krikri::PythonLookupRunner.call_lookup("mylookup", File.join(bin, "plugin.py"),
          [] of JSON::Any, {} of String => JSON::Any, {} of String => JSON::Any)
      end
      ex.unavailable?.must_equal(true)
    ensure
      ENV["PATH"] = previous
      FileUtils.rm_r(bin)
    end
  end
end
