require "./spawn_error"
require "./bigint_json"

module Krikri
  # Which Python interpreter a CONTROLLER-side wrapper run (the custom
  # lookup/filter/test/action plugin mechanisms) gets spawned under, and
  # the one-place retry when the plain `python3` on PATH cannot serve it.
  #
  # The runners used to spawn the first `python3`/`python` on PATH and
  # stamp `{"kind": "unavailable"}` when that interpreter could not
  # import the `ansible` package - which every caller degrades to its
  # pre-custom-plugin behavior, i.e. a lookup()/query() of a plugin that
  # DOES exist silently becomes `null`. On a controller where Ansible is
  # not installed for that interpreter (the common Homebrew/pipx
  # layouts: `python3` on PATH is Xcode's or a Homebrew python without
  # the `ansible` package, while `ansible-playbook` runs under its own
  # venv interpreter) that produced exactly the issue #778 symptom -
  # real ansible-playbook runs the plugin, krikri returns null.
  #
  # So: when a wrapper answers "unavailable", retry once under the
  # interpreter the user's own `ansible-playbook`/`ansible` runs under
  # (its shebang line), then any other `python3*` on PATH that can
  # import ansible. Nothing changes when the first interpreter works,
  # and nothing changes when NONE of them can import ansible (the
  # degradation stays exactly as before) - a wrapper that answered
  # anything other than "unavailable" is never retried, so a fake/dying
  # interpreter keeps the #704/#705 spawn classification.
  #
  # Probing is cached: per interpreter path (a path's answer never
  # changes) and per PATH/HOME pair (which candidates exist at all), so
  # a run pays for at most one probe per candidate, not one per lookup.
  module ControllerPython
    extend self

    alias Captured = NamedTuple(status: Process::Status, stdout: String, stderr: String)

    # The capability probe. `ansible.plugins` is the package every
    # wrapper imports from (`ansible.plugins.lookup.LookupBase` and
    # friends), so an interpreter that cannot import it cannot serve any
    # of them.
    PROBE = "import ansible.plugins"

    # Interpreter basenames tried after the ansible binaries' own
    # shebangs: the plain names first (what the runners always used),
    # then the versioned ones, newest first, so a controller whose
    # `python3` lacks ansible but whose `python3.13` has it still works.
    PYTHON_NAMES = %w[python3 python python3.14 python3.13 python3.12
      python3.11 python3.10 python3.9 python3.8 python3.7]

    @@capability = {} of String => Bool
    @@capability_mutex = Mutex.new
    @@capable = {} of String => Array(String)
    @@capable_mutex = Mutex.new
    @@ansible_python = {} of String => String?
    @@ansible_python_mutex = Mutex.new

    # The plain controller interpreter - unchanged behavior, the first
    # `python3`/`python` on PATH.
    def executable : String?
      Process.find_executable("python3") || Process.find_executable("python")
    end

    # The interpreter the user's own `ansible-playbook` (then `ansible`)
    # runs under, read from its `#!` line. Real ansible runs every
    # module of a `delegate_to: localhost` task under exactly this
    # Python: it is real's `sys.executable`, which ansible-core stamps
    # onto the implicit localhost host as `ansible_python_interpreter`
    # (inventory/data.py `_create_implicit_localhost`), so libraries
    # installed beside ansible - boto3 for amazon.aws, issue #1005 -
    # are importable there and nowhere else. nil when no ansible binary
    # is on PATH (or none names a python): there is then no ansible
    # behavior to match, and callers keep discovery.
    def ansible_python : String?
      signature = choice_signature
      @@ansible_python_mutex.synchronize do
        if @@ansible_python.has_key?(signature)
          return @@ansible_python[signature]
        end
      end
      found : String? = nil
      {"ansible-playbook", "ansible"}.each do |binary|
        if interpreter = shebang_interpreter(binary)
          found = interpreter
          break
        end
      end
      @@ansible_python_mutex.synchronize { @@ansible_python[signature] = found }
      found
    end

    # Gives *vars* the interpreter real ansible's implicit localhost
    # carries. Only the IMPLICIT localhost gets it (real's
    # `_create_implicit_localhost` runs only when no inventory defines
    # localhost, and `set_variable` would not override one that does),
    # so callers apply this exactly where they synthesize that host or
    # its hostvars entry.
    def apply_implicit_localhost_interpreter(vars : Hash(String, JSON::Any)) : Nil
      return if vars.has_key?("ansible_python_interpreter")
      return unless python = ansible_python
      vars["ansible_python_interpreter"] = JSON::Any.new(python)
    end

    # Whether *python* can import the `ansible` package. Cached per path;
    # a probe that cannot even spawn the interpreter is a plain false.
    def ansible_importable?(python : String) : Bool
      @@capability_mutex.synchronize do
        if cached = @@capability[python]?
          return cached
        end
      end
      result = probe(python)
      @@capability_mutex.synchronize { @@capability[python] = result }
      result
    end

    # The first interpreter OTHER than *primary* that can import ansible,
    # or nil when the controller has none. Order: the shebang interpreter
    # of `ansible-playbook` then `ansible` (the interpreter real ansible
    # itself runs under - the pipx/Homebrew case), then every `python3*`
    # on PATH.
    def ansible_capable(primary : String? = nil) : String?
      capable_interpreters.find { |candidate| candidate != primary }
    end

    # Every candidate that can import ansible, in candidate order.
    private def capable_interpreters : Array(String)
      signature = choice_signature
      @@capable_mutex.synchronize do
        if cached = @@capable[signature]?
          return cached
        end
      end
      list = candidates.select { |candidate| ansible_importable?(candidate) }
      @@capable_mutex.synchronize { @@capable[signature] = list }
      list
    end

    # Runs *wrapper* (the `-c` program) against *stdin* under *python*,
    # retrying once under an ansible-capable interpreter when the first
    # one answered `{"ok": false, "kind": "unavailable"}` (it ran, it
    # just cannot import ansible - the issue #778 case). Spawn
    # classification is the runners' own: only a PRE-spawn failure
    # raises Krikri::SpawnError, a wrapper that ran keeps its answer.
    def run_wrapper(python : String?, wrapper : String, stdin : String) : Captured?
      return nil unless python
      captured = Krikri.run_captured_helper(python, ["-c", wrapper], stdin)
      return captured unless captured && ansible_unavailable?(captured)
      alternative = ansible_capable(python)
      return captured unless alternative
      begin
        Krikri.run_captured_helper(alternative, ["-c", wrapper], stdin) || captured
      rescue SpawnError
        # The interpreter that DID run answered; a retry that cannot even
        # start is not a new verdict.
        captured
      end
    end

    private def probe(python : String) : Bool
      process = begin
        Process.new(python, ["-c", PROBE],
          input: Process::Redirect::Close, output: Process::Redirect::Close,
          error: Process::Redirect::Close)
      rescue File::Error
        # A vanished/bad interpreter: the same silent nil LocalExecutor's
        # #704 carve-out gives a stale find_executable answer.
        return false
      rescue
        return false
      end
      process.wait.success?
    rescue
      false
    end

    # A wrapper answer that says only "the ansible package is not
    # importable by this interpreter" - the one retry-worthy verdict.
    # Callers that read their wrapper's answer as JSON (the interactive
    # action IPC loop) share the same test.
    def ansible_unavailable?(answer : JSON::Any?) : Bool
      hash = answer.try(&.as_h?)
      return false unless hash
      return false unless hash["ok"]?.try(&.as_bool?) == false
      hash["kind"]?.try(&.as_s?) == "unavailable"
    end

    private def ansible_unavailable?(captured : Captured) : Bool
      return false unless captured[:status].success?
      line = captured[:stdout].lines.reject(&.blank?).last?
      return false unless line
      parsed = (Krikri::BigJson.parse(line) rescue return false)
      ansible_unavailable?(parsed)
    end

    private def candidates : Array(String)
      list = [] of String
      {"ansible-playbook", "ansible"}.each do |binary|
        if interpreter = shebang_interpreter(binary)
          list << interpreter
        end
      end
      PYTHON_NAMES.each do |name|
        if path = Process.find_executable(name)
          list << path
        end
      end
      list.uniq
    end

    # The interpreter an ansible binary actually runs under, read from
    # its `#!` line - how a pipx (`#!/home/u/.local/pipx/venvs/
    # ansible-core/bin/python`) or Homebrew (`#!/opt/homebrew/opt/
    # python@3.13/bin/python3.13`) install names it. `#!/usr/bin/env
    # python3` resolves through PATH, and a non-python shebang (a wrapper
    # shell script) yields nil.
    private def shebang_interpreter(binary : String) : String?
      path = Process.find_executable(binary)
      return nil unless path
      first = (File.open(path) { |io| io.gets(chomp: true) } rescue nil)
      return nil unless first && first.starts_with?("#!")
      parts = first[2..].strip.split(/\s+/)
      return nil if parts.empty?
      program = parts[0]
      if File.basename(program) == "env"
        program = parts[1..].find { |arg| !arg.starts_with?("-") } || return nil
        return Process.find_executable(program)
      end
      return nil unless File.basename(program).starts_with?("python")
      return program if File::Info.executable?(program)
      nil
    end

    # The cache key for `ansible_capable` - which candidates exist (and
    # which one `ansible-playbook` names) depends on these two values, so
    # a spec that points PATH or HOME elsewhere gets a fresh answer.
    private def choice_signature : String
      "#{ENV["PATH"]?}\u0000#{ENV["HOME"]?}\u0000#{ENV["USERPROFILE"]?}"
    end
  end
end
