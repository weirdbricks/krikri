require "../minitest_helper"

# Runs the compiled binary against a real playbook: this is about the
# template action plugin's trailing-newline convention on the rendered
# file, not the hand-rolled plain {{ }} evaluator.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_template(src_content : String, tag : String) : {String, String, String, String}
  src = File.tempname("#{tag}-src", ".j2")
  dest = File.tempname("#{tag}-dest")
  playbook = File.tempname(tag, ".yml")
  File.write(src, src_content)

  File.write(playbook, <<-YAML)
    - name: repro
      hosts: localhost
      gather_facts: false
      vars:
        users: []
      tasks:
        - name: render
          ansible.builtin.template:
            src: #{src}
            dest: #{dest}
    YAML

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  status.success?.must_equal(true)
  {src, dest, playbook, output.to_s}
end

describe "a template whose rendered output is the empty string" do
  it "writes a 0-byte dest instead of appending a newline" do
    # Live-verified vs ansible-core 2.19.11: a template body of
    # `{% for u in users %}\n"{{ u }}"\n{% endfor %}` with users=[]
    # renders to "" and Ansible writes a 0-byte file; krikri used to
    # apply the trailing-newline convention to the empty string too,
    # writing "\n" (size 1) and reporting `changed` on a rerun against
    # an existing empty dest where Ansible reports `ok`.
    src, dest, playbook, _ = run_template(
      "{% for u in users %}\n\"{{ u }}\"\n{% endfor %}", "empty-render")
    begin
      File.size(dest).must_equal(0)
    ensure
      File.delete(src)
      File.delete(dest)
      File.delete(playbook)
    end
  end

  it "does not add a newline the template source never had" do
    # Live-verified vs ansible-core 2.19.11: the trailing-newline
    # convention is a count comparison, not a guaranteed append - a
    # template source ending without a newline yields a file without
    # one too; krikri used to append exactly one "\n" regardless.
    src, dest, playbook, _ = run_template(
      "{% for u in users %}x{% endfor %}hello", "nonempty-render")
    begin
      File.read(dest).must_equal("hello")
    ensure
      File.delete(src)
      File.delete(dest)
      File.delete(playbook)
    end
  end

  it "restores every trailing newline the template source lost" do
    # Live-verified vs ansible-core 2.19: the template action counts the
    # trailing newlines of the source against those of the rendered
    # result and appends the difference, so a source ending in two
    # newlines keeps both in the file even though the engine chomped
    # one; krikri used to append at most one regardless.
    src, dest, playbook, _ = run_template(
      "{% for u in users %}x{% endfor %}hello\n\n", "trailing-newline-count")
    begin
      File.read(dest).must_equal("hello\n\n")
    ensure
      File.delete(src)
      File.delete(dest)
      File.delete(playbook)
    end
  end
end
