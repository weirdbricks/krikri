require "../minitest_helper"
require "file_utils"

# plugin_helpers/python_lib_gate.cr picks the interpreter real's
# missing_required_lib() names, and it has to match real's interpreter
# DISCOVERY: real runs `command -v` over INTERPRETER_PYTHON_FALLBACK
# (python3.13 ... python3.8, /usr/bin/python3, python3) and hands the
# module the first hit, so the sys.executable basic.py prints is that
# interpreter's. This gate probed a bare `python3` instead, which on a
# Debian box resolves to the /usr/bin/python3 SYMLINK and reported
# ".../python3" where real reported ".../python3.13" - found via the kpg33
# generator re-sweep, where all 13 divergent expect playbooks differed in
# exactly that one path.
#
# The gate also re-ran sys.executable's own output as a command, which
# aborts the plugin process when that path is not on PATH (a relocated
# venv, a container image layer); it now probes with the interpreter it
# discovered.

require "../../src/krikri/plugin_helpers/python_lib_gate"

# The interpreter real's discovery would land on for this host: the first
# INTERPRETER_PYTHON_FALLBACK entry `command -v` resolves.
private def real_discovered_interpreter : String?
  Krikri::INTERPRETER_FALLBACK.each do |name|
    if resolved = Process.find_executable(name)
      return resolved
    end
  end
  nil
end

private def missing_lib_message(library : String, python : String) : String
  "Failed to import the required Python library (#{library}) on #{System.hostname}'s Python #{python}. " \
  "Please read the module documentation and install it in the appropriate location. " \
  "If the required library is installed, but Ansible is using the wrong Python interpreter, " \
  "please consult the documentation on ansible_python_interpreter"
end

describe "python library gate interpreter discovery" do
  serial!

  it "falls back to the interpreters real's INTERPRETER_PYTHON_FALLBACK would try" do
    Krikri::INTERPRETER_FALLBACK.must_equal([
      "python3.13", "python3.12", "python3.11", "python3.10",
      "python3.9", "python3.8", "/usr/bin/python3", "python3",
    ])
  end

  it "names the interpreter real's discovery picks, not a bare python3" do
    interpreter = real_discovered_interpreter
    skip "host has no python in real's fallback list" unless interpreter

    # The interpreter reports its own sys.executable, exactly like the
    # module process real runs under the discovered interpreter does.
    reported = IO::Memory.new
    Process.run(interpreter, {"-c", "import sys; print(sys.executable)"},
      output: reported, error: Process::Redirect::Close)

    Krikri.target_python_executable.must_equal(reported.to_s.strip)
  end

  it "reports the missing-library message against that interpreter" do
    skip "host has no python in real's fallback list" unless real_discovered_interpreter

    # A library that exists nowhere always fails to import, so the gate
    # fires and the message names the discovered interpreter.
    python = Krikri.target_python_executable
    gate = Krikri.missing_python_library("krikri_no_such_python_library", "krikri_no_such_python_library")
    return if python.nil? || gate.nil?
    gate[:msg].must_equal(missing_lib_message("krikri_no_such_python_library", python))
    gate[:detail].must_include("No module named 'krikri_no_such_python_library'")
  end

  it "probes with the discovered interpreter, not with its sys.executable string" do
    dir = PluginSpecHelper.tmp_path("gate-relocated-python")
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    interpreter = File.join(dir, Krikri::INTERPRETER_FALLBACK.first)
    File.write(interpreter, <<-SHIM)
      #!/bin/sh
      case "$*" in
        *"print(sys.executable)"*) echo "/opt/krikri-absent/bin/python3.13" ;;
        *"import krikri_no_such_python_library"*)
          echo "ModuleNotFoundError: No module named 'krikri_no_such_python_library'" >&2
          exit 1 ;;
        *) exit 0 ;;
      esac
      SHIM
    File.chmod(interpreter, 0o755)

    # The shim wins discovery but points sys.executable at a path that
    # does not exist - running THAT string used to raise out of the
    # plugin process instead of reporting the missing library.
    original_path = ENV["PATH"]?
    ENV["PATH"] = "#{dir}:#{original_path}"
    begin
      Krikri.discovered_target_python.must_equal(interpreter)

      if gate = Krikri.missing_python_library("krikri_no_such_python_library", "krikri_no_such_python_library")
        gate[:msg].must_equal(
          missing_lib_message("krikri_no_such_python_library", "/opt/krikri-absent/bin/python3.13"))
      else
        raise "the fake interpreter should have failed the import"
      end
    ensure
      ENV["PATH"] = original_path if original_path
      FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
    end
  end
end
