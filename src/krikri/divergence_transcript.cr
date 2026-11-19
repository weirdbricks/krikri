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
    # What a case's scratch directory is rewritten to. ONLY this path is
    # normalized; everything else in a transcript has to match byte for byte.
    WORK = "<WORK>"

    # Rewrite *work_dir* (and everything under it) to `<WORK>`. A transcript
    # can name the case directory dozens of times (Origin blocks, `included:`
    # lines, every copied role path) and each run happens in a fresh directory,
    # so the path is the one thing that cannot be pinned verbatim.
    def self.normalize(text : String, work_dir : String) : String
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

    # The full argument list after the binary name, run from inside the case's
    # scratch directory.
    def self.run_args(case_dir : String) : Array(String)
      inventory_args(case_dir) + ["-c", "local"] + flags(case_dir) + [PLAYBOOK]
    end

    # Everything a run must not inherit from the developer's or the runner's
    # shell: this box exports ANSIBLE_GATHERING/ANSIBLE_CACHE_PLUGIN, which
    # change both the task list and the facts, and HOME decides where `~`
    # points (a case may use `~/...`, and must never write into the real home
    # directory).
    def self.env(home_dir : String) : Hash(String, String?)
      {
        "ANSIBLE_NOCOLOR"                 => "1",
        "HOME"                            => home_dir,
        "ANSIBLE_GATHERING"               => nil,
        "ANSIBLE_CACHE_PLUGIN"            => nil,
        "ANSIBLE_CACHE_PLUGIN_CONNECTION" => nil,
      }
    end
  end
end
