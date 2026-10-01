require "json"

module Krikri
  # Real's missing_required_lib(<library>) message, verbatim
  # (module_utils/basic.py), for a target that cannot import <library>.
  #
  # The shape of the parity problem this covers: several real modules
  # import a Python library at MODULE level, so a target without it
  # fails the task with this message before the module validates a
  # single one of its own arguments. krikri implements those modules
  # natively (its own pty layer for expect, its own XML parser for
  # xml) and therefore does NOT need the library - which is why it used
  # to carry on past the point where real stops, reporting its own
  # downstream failure (or, worse, success) instead. The dependency
  # still decides the outcome, so it is reproduced here: same message,
  # same ordering, same point in the flow. Same precedent as the
  # python3-debian gate in deb822_repository, the gssapi gate in
  # nsupdate/url_preflight and the boto3 gate in the aws modules.
  def self.missing_required_lib_message(library : String, python : String) : String
    "Failed to import the required Python library (#{library}) on #{System.hostname}'s Python #{python}. " \
    "Please read the module documentation and install it in the appropriate location. " \
    "If the required library is installed, but Ansible is using the wrong Python interpreter, " \
    "please consult the documentation on ansible_python_interpreter"
  end

  # The target's Python interpreter, the way real's missing_required_lib
  # names it (the interpreter's own sys.executable, not the bare name):
  # `python3` first, then `python`. nil when the target has neither.
  #
  # This runs on the TARGET (each plugin binary is uploaded there), so
  # both the probe and the hostname it reports are the target's own -
  # the same two values real's import failure reports.
  def self.target_python_executable : String?
    ["python3", "python"].each do |name|
      next unless Process.find_executable(name)
      io = IO::Memory.new
      status = Process.run(name, {"-c", "import sys; print(sys.executable)"}, output: io, error: Process::Redirect::Close)
      path = io.to_s.strip
      return path if status.success? && !path.empty?
    end
    nil
  end

  # nil when <import_stmt> imports cleanly under the target's Python -
  # the module carries on, exactly as real's does. Otherwise real's
  # exact failure text.
  #
  # `detail` is the ImportError's own text for the modules that pass
  # their caught exception along (`module.fail_json(msg=
  # missing_required_lib("pexpect"), exception=PEXPECT_IMP_ERR)`), which
  # real shows in the [ERROR] block only - never in the result's msg -
  # so it is returned SEPARATELY, for the caller to pass as the
  # [ERROR]-only detail rather than appended to the message.
  def self.missing_python_library(library : String, import_stmt : String) : {msg: String, detail: String}?
    return nil unless python = target_python_executable

    err = IO::Memory.new
    status = Process.run(python, {"-c", "import #{import_stmt}"}, error: err, output: Process::Redirect::Close)
    return nil if status.success?

    msg = missing_required_lib_message(library, python)
    # Python's own ImportError tail ("No module named 'pexpect'"), which
    # is what real hands fail_json as `exception` - the traceback's last
    # line, "ModuleNotFoundError: No module named 'pexpect'".
    reason = err.to_s.lines.last?.try(&.strip).try { |line| line.includes?("Error") ? line.split(": ", 2).last : nil }
    {msg: msg, detail: reason ? "#{msg}: #{reason}" : ""}
  end
end
