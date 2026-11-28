# Shared transcript handling for the divergence regression corpus.
#
# A corpus case records ONE transcript per divergence: what real
# ansible-playbook printed, normalized so it can be compared against what
# krikri-playbook prints for the same case in a different scratch directory.
# Both sides go through this module - the capture tool
# (`bin/krikri-capture-case`) writes `expected.out` with it, and the replay
# spec (`test/integration/divergence_corpus_test.cr`) reads/replays through it
# - so the two can never drift into different placeholder spellings, stream
# orderings or failure reports.
module Krikri
  module DivergenceTranscript
    # What a case's scratch directory is rewritten to. The scratch path, the
    # order of convert_bool's boolean enumeration, the values of command/shell's
    # three timing fields and the stamp in npm's own debug-log file name below
    # are the only normalized things; everything else in a transcript has to
    # match byte for byte.
    WORK = "<WORK>"

    # command/shell report `start`/`end`/`delta`, and all three are the wall
    # clock at each engine's OWN run moment: two runs of real ansible disagree
    # on them exactly like the two engines do, so a case whose transcript
    # carries a failed (or otherwise printed) command result could never match
    # without this. The round harness masks the same three fields as `<TIME>`.
    # Keys, quoting and the value's format stay in the transcript; only the
    # per-run numbers are replaced.
    TIMING_FIELD = /(["'](?:start|end|delta)["']: ["'])(?:\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?|(?:\d+ days?, )?\d+:\d\d:\d\d(?:\.\d+)?)(["'])/
    TIME         = "<TIME>"

    # convert_bool builds "Valid booleans include:" by iterating a Python
    # frozenset, so its order is randomized per module process (string hash
    # randomization): two consecutive real ansible runs of the same play
    # already disagree byte for byte. Only the ORDER is noise - membership is
    # part of the message - so the members are sorted into one deterministic
    # order for the recording and every replay. Only the repr'd members are
    # captured: a JSON fatal line continues after the list, and its closing
    # `"}` must stay outside the sort.
    BOOLEAN_ENUMERATION = /(Valid booleans include: )((?:'[^']*'|True|False|\d+(?:\.\d+)?)(?:, (?:'[^']*'|True|False|\d+(?:\.\d+)?))*)(?=\n|"|\z)/

    # npm names its debug log after the wall-clock moment it started
    # (`$HOME/.npm/_logs/<stamp>-debug-0.log`) and repeats that path in the
    # failure's msg, stderr and stderr_lines, so two runs of EITHER engine
    # disagree on it (issue #1970: two real ansible runs printed
    # `...T08_30_32_869Z` and `...T09_29_21_959Z` while every other byte of the
    # task matched). Only the stamp inside an `_logs/` file name is replaced:
    # the directory, the `-debug-<n>.log` suffix and the wording around it stay
    # in the transcript, which is what still catches a wrong log path.
    NPM_LOG_STAMP = /(\.npm\/_logs\/)\d{4}-\d\d-\d\dT\d\d_\d\d_\d\d_\d+Z(?=-debug-)/
    NPM_LOG_TIME  = "<NPM_LOG_TIME>"

    # Rewrite *work_dir* (and everything under it) to `<WORK>`, sort the
    # boolean enumeration, blank the command timing values and mask npm's
    # debug-log stamp. A transcript can name the case directory dozens of times
    # (Origin blocks, `included:` lines, every copied role path) and each run
    # happens in a fresh directory, so the path is the one path that cannot be
    # pinned verbatim.
    def self.normalize(text : String, work_dir : String) : String
      text = text.gsub(BOOLEAN_ENUMERATION) do |_match, captures|
        "#{captures[1]}#{captures[2].to_s.split(", ").sort!.join(", ")}"
      end
      text = text.gsub(TIMING_FIELD) do |_match, captures|
        "#{captures[1]}#{TIME}#{captures[2]}"
      end
      text = text.gsub(NPM_LOG_STAMP) do |_match, captures|
        "#{captures[1]}#{NPM_LOG_TIME}"
      end
      return text if work_dir.empty?
      # Only rewrite *work_dir* when it is a whole path, not a prefix of a
      # longer one: a lookalike sibling like `<work_dir>-lookalike` or
      # `<work_dir>2` is a different directory and must keep its own spelling,
      # or two engines' transcripts could be forced equal by an over-broad
      # replacement. A real use is followed by `/` (a child path) or by a
      # non-name character (space, quote, end of string).
      text.gsub(Regex.new("#{Regex.escape(work_dir)}(?![A-Za-z0-9._-])"), WORK)
    end

    # A transcript is stdout followed by stderr. A `2>&1` capture is NOT
    # reproducible across the two engines: python block-buffers stdout when it
    # is redirected, so real ansible's stderr arrives as one block after all of
    # stdout, while krikri's line-buffered stream interleaves with its own.
    # Concatenating the two streams each engine wrote keeps both deterministic.
    def self.combine(stdout : String, stderr : String, work_dir : String) : String
      normalize("#{stdout}#{stderr}", work_dir)
    end

    # The failure message for a replay whose transcript differs: the first
    # diverging line with three lines of context on either side, plus both
    # sizes. Comparing two whole transcripts through assert_equal alone buries
    # that one line in ~100 identical ones.
    def self.report(expected : String, actual : String) : String
      return "" if expected == actual

      expected_lines = expected.lines
      actual_lines = actual.lines
      index = (0...Math.max(expected_lines.size, actual_lines.size)).find do |position|
        expected_lines[position]? != actual_lines[position]?
      end || 0

      out = IO::Memory.new
      out << "transcript diverges at line #{index + 1}\n"
      (Math.max(0, index - 3)...index).each do |position|
        out << "  #{expected_lines[position]?}\n"
      end
      out << "- #{expected_lines[index]?}\n"
      out << "+ #{actual_lines[index]?}\n"
      (index + 1...[index + 4, actual_lines.size].min).each do |position|
        out << "  #{actual_lines[position]?}\n"
      end
      out << "expected #{expected.bytesize} bytes, got #{actual.bytesize} bytes\n"
      out.to_s
    end
  end
end

# A divergence corpus case's INPUT conventions: which files are the case (and
# which are its recorded result), how a case's optional `flags.txt` and
# `inventory.ini` turn into ansible/krikri command-line arguments, and the
# environment every capture and replay runs under. Shared for the same reason
# the transcript handling is: the capture tool and the replay spec must agree
# on the invocation, or a case would be captured under one and replayed under
# another.
module Krikri
  module DivergenceCase
    PLAYBOOK  = "playbook.yml"
    INVENTORY = "inventory.ini"
    FLAGS     = "flags.txt"
    ENV_FILE  = "env.txt"

    # The case's recorded result, not part of its input. Never copied into a
    # scratch run and never fed back into a capture.
    RECORDED = {"expected.out", "NOTES.md"}

    # One CLI flag per line, e.g. `--check` or `-e` followed by
    # `name=value` on the next line. Blank lines and surrounding whitespace
    # are ignored so the files stay readable.
    def self.flags(case_dir : String) : Array(String)
      path = File.join(case_dir, FLAGS)
      return [] of String unless File.exists?(path)
      File.read_lines(path).map(&.strip).reject(&.empty?)
    end

    # Copy a case's INPUT (everything but RECORDED) into *work_dir*, which must
    # already exist. `FileUtils.cp_r` copies a file's permission bits but
    # creates directories with the process umask's mode - and a case's own
    # directory mode in the checkout comes from the umask too, since git
    # records no directory modes. Mirroring either one made a case's replay
    # depend on who ran it: a `plugins/` root that is a normal 0755 in one
    # checkout is 0775 under umask 002, and krikri's external plugin registry
    # refuses a group/world-writable root, failing the replay before the
    # playbook runs (issue #1757). Normalize instead of trusting either side;
    # a directory mode no recording can reproduce is not part of the case.
    def self.copy_inputs(case_dir : String, work_dir : String) : Nil
      Dir.children(case_dir).each do |entry|
        next if RECORDED.includes?(entry)
        source = File.join(case_dir, entry)
        dest = File.join(work_dir, entry)
        FileUtils.cp_r(source, dest)
        normalize_directory_modes(dest) if File.directory?(source)
      end
    end

    private def self.normalize_directory_modes(dir : String) : Nil
      File.chmod(dir, 0o755)
      Dir.each_child(dir) do |entry|
        child = File.join(dir, entry)
        normalize_directory_modes(child) if File.directory?(child)
      end
    end

    # A case that executes modules ships an inventory whose `[local]` host pins
    # ansible_connection/ansible_python_interpreter - the one placement both
    # engines resolve identically, and what keeps the interpreter-discovery
    # warning (unmatchable by design, see KNOWN_MISSING.md) out of the
    # transcript. Cases without one run against the implicit localhost.
    def self.inventory_args(case_dir : String) : Array(String)
      if File.exists?(File.join(case_dir, INVENTORY))
        ["-i", INVENTORY]
      else
        ["-i", "localhost,"]
      end
    end

    # One NAME=value per line. A case whose trigger is the RUNNING process's
    # own environment - not the play's `environment:` keyword, which only the
    # module process sees - has to state it here or it would be recorded
    # against, and replayed on, whatever PATH the capturing shell happened to
    # have. Issue #1643's synchronize case needs a PATH with no rsync on it.
    def self.env_overrides(case_dir : String) : Hash(String, String)
      path = File.join(case_dir, ENV_FILE)
      return {} of String => String unless File.exists?(path)

      overrides = {} of String => String
      File.read_lines(path).each do |line|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        name, separator, value = line.partition('=')
        next unless separator == "=" && !name.strip.empty?
        overrides[name.strip] = value.strip
      end
      overrides
    end

    # The full argument list after the binary name, run from inside the case's
    # scratch directory.
    def self.run_args(case_dir : String) : Array(String)
      inventory_args(case_dir) + ["-c", "local"] + flags(case_dir) + [PLAYBOOK]
    end

    # The PATH a case runs under. A module's get_bin_path failure names every
    # directory it searched, so an inherited PATH (this box's carries a random
    # AppImage mount point) would make the transcript differ between the
    # recording and every replay; the standard system directories are the same
    # on every host and already include the three sbin dirs get_bin_path
    # appends.
    CASE_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    # A container client's daemon is part of a case's input, not of the
    # developer's or the runner's shell: with DOCKER_HOST inherited, a case
    # recorded against an unreachable socket connected to rootless podman
    # instead - real ansible then succeeded where the recording failed, and
    # the capture gate reported the case's expected.out as not reproducible
    # (issue #1611). Unset, the docker CLI/SDK falls back to
    # /var/run/docker.sock, the one target a recording and its replays share.
    DOCKER_ENV = [
      "DOCKER_HOST",
      "DOCKER_CONTEXT",
      "DOCKER_CONFIG",
      "DOCKER_TLS",
      "DOCKER_TLS_VERIFY",
      "DOCKER_TLS_HOSTNAME",
      "DOCKER_CERT_PATH",
      "DOCKER_API_VERSION",
    ]

    # Everything a run must not inherit from the developer's or the runner's
    # shell: this box exports ANSIBLE_GATHERING/ANSIBLE_CACHE_PLUGIN, which
    # change both the task list and the facts, HOME decides where `~` points
    # (a case may use `~/...`, and must never write into the real home
    # directory), PATH is pinned for the reason above, and the docker daemon
    # selectors are cleared for the reason in DOCKER_ENV. The case's own
    # env.txt overrides go on top, so a case may need a different PATH than
    # the harness default (see DivergenceCase.env_overrides).
    def self.env(home_dir : String, case_dir : String) : Hash(String, String?)
      env = {
        "ANSIBLE_NOCOLOR"                 => "1",
        "HOME"                            => home_dir,
        "PATH"                            => CASE_PATH,
        "ANSIBLE_GATHERING"               => nil,
        "ANSIBLE_CACHE_PLUGIN"            => nil,
        "ANSIBLE_CACHE_PLUGIN_CONNECTION" => nil,
      }
      DOCKER_ENV.each { |name| env[name] = nil }
      env_overrides(case_dir).each { |name, value| env[name] = value }
      env
    end
  end
end
