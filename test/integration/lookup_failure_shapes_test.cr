require "../minitest_helper"
require "file_utils"

# Lookup-plugin console shapes vs real ansible-playbook 2.19.11
# (live-verified via scripts/output_parity.sh):
# - a failing lookup('file', ...) rides the "Finalization of task args"
#   chain, and the message carries real's "Use -vvvvv to see paths
#   searched." suffix;
# - lookup('vars', missing) says "No variable named 'X' was found.";
# - lookup('first_found', ..., errors='ignore') renders empty;
# - ini/csvfile lookups take their options as keyword arguments
#   (file=, section=/field=/col=, default=) and default to a TAB
#   delimiter (csvfile);
# - relative copy: dest and lookups resolve against the PLAYBOOK's
#   directory (real ansible-playbook chdirs there at startup), even when
#   invoked from a different cwd.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "lookup plugin failure and kwarg shapes" do
  it "wraps file failures, names missing vars, honors errors=ignore and lookup kwargs" do
    playbook = File.tempname("lookup-shapes", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        tasks:
          - copy:
              content: "hello from file"
              dest: parity.txt
          - debug: msg="f={{ lookup('file', 'parity.txt') }}"
          - debug: msg="file={{ lookup('file', '/nonexistent-parity-file.txt') }}"
            ignore_errors: true
          - debug: msg="ff={{ lookup('first_found', ['no-such-file.yml'], errors='ignore') }}"
          - debug: msg="vars={{ lookup('vars', 'nope_var') }}"
            ignore_errors: true
      YAML
    output = IO::Memory.new
    # Run from a DIFFERENT cwd: relative paths must resolve against the
    # playbook's own directory.
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: temp_workdir)
    text = output.to_s

    text.must_include(%("msg": "f=hello from file"))
    text.must_include("The lookup plugin 'file' failed: Unable to access the file '/nonexistent-parity-file.txt': File not found. Use -vvvvv to see paths searched.")
    text.must_include(%("msg": "ff="))
    text.must_include("No variable named 'nope_var' was found.")
    # the copy landed next to the PLAYBOOK, and the lookup read it there
    File.exists?(File.join(File.dirname(playbook), "parity.txt")).must_equal(true)
  ensure
    playbook.try { |pb| File.delete(pb) if File.exists?(pb) }
    File.delete(File.join(File.dirname(pb_path(playbook)), "parity.txt")) rescue nil
  end

  private def pb_path(playbook)
    playbook || ""
  end

  private def temp_workdir
    dir = File.tempname("lookup-cwd", "")
    Dir.mkdir(dir)
    dir
  end
end
