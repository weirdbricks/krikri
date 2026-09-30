require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# Real's template ACTION plugin encodes the rendered result into its own
# temporary file with Python's to_bytes(resultant, encoding=output_encoding)
# BEFORE it hands anything to the copy action plugin, so a non-string
# output_encoding crashes there - "encode() argument 'encoding' must be str,
# not _AnsibleTaggedInt" - and the copy module's own spec never runs at all.
# That is what the task reports, not a typo'd key or a wrong-typed bool
# sitting next to the literal, and not in check mode either (the encode
# happens before copy's own --check short-circuit). A FALSY literal is
# instead silently the default (real's `or 'utf-8'`) and deploys. All
# live-verified vs 2.19.11. The playbooks live in the per-test scratch dir;
# dests are under it too.
private def template_probe(name : String, task_body : String, args : Array(String) = [] of String) : {String, String}
  src = PluginSpecHelper.tmp_path("#{name}.j2")
  dest = PluginSpecHelper.tmp_path("#{name}-out.txt")
  File.write(src, "hello\n")
  File.delete(dest) if File.exists?(dest)

  playbook = PluginSpecHelper.tmp_path("#{name}.yml")
  task_lines = task_body.lines.map(&.chomp).reject(&.empty?).map { |line| "        #{line}" }.join("\n")
  File.write(playbook,
    "- name: repro\n" +
    "  hosts: localhost\n" +
    "  gather_facts: false\n" +
    "  tasks:\n" +
    "    - name: template #{name}\n" +
    "      ansible.builtin.template:\n" +
    "        src: #{src}\n" +
    "        dest: #{dest}\n" +
    "#{task_lines}\n" +
    "      ignore_errors: true\n")

  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook] + args, output: output, error: output)
  {output.to_s, dest}
ensure
  # The dest is deliberately left on disk: callers assert on the bytes
  # real would have written, and it lives in the per-test scratch dir
  # (PluginSpecHelper.tmp_path), which the suite cleans up itself.
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "template: output_encoding is encoded by the action plugin" do
  it "crashes the action plugin on an int output_encoding" do
    out, _ = template_probe("enc-int", "output_encoding: 63\n")

    out.must_include("[ERROR]: Task failed: encode() argument 'encoding' must be str, not _AnsibleTaggedInt")
    out.must_include("\"msg\": \"Task failed: encode() argument 'encoding' must be str, not _AnsibleTaggedInt\"")
    out.wont_include("Module failed")
  end

  it "reports the encoding crash, not a typo'd key beside it" do
    out, _ = template_probe("enc-int-typo", "output_encoding: 63\nbakcup: false\nlstripb_locks: false\n")

    out.must_include("encode() argument 'encoding' must be str, not _AnsibleTaggedInt")
    out.wont_include("Unsupported parameters")
  end

  it "reports the encoding crash, not a wrong-typed bool beside it" do
    out, _ = template_probe("enc-int-bool", "output_encoding: 63\nbackup: notabool\n")

    out.must_include("encode() argument 'encoding' must be str, not _AnsibleTaggedInt")
    out.wont_include("argument 'backup' is of type str")
  end

  it "reports the encoding crash under --check too" do
    out, _ = template_probe("enc-int-check", "output_encoding: 63\n", ["--check"])

    out.must_include("encode() argument 'encoding' must be str, not _AnsibleTaggedInt")
    out.wont_include("Unsupported parameters")
  end

  it "reports an action-level failure ahead of a missing source file" do
    playbook = PluginSpecHelper.tmp_path("enc-missing-src.yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: template missing src
            ansible.builtin.template:
              src: #{PluginSpecHelper.tmp_path("enc-absent.j2")}
              dest: #{PluginSpecHelper.tmp_path("enc-absent.txt")}
              output_encoding: 63
            ignore_errors: true
    YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    output.to_s.must_include("Could not find or access")
    output.to_s.wont_include("encode() argument")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "names the Python type real reports for each non-string value" do
    {"float" => ["1.5", "_AnsibleTaggedFloat"],
     "bool"  => ["true", "bool"],
     "list"  => ["[7]", "_AnsibleTaggedList"],
     "dict"  => ["{a: 1}", "_AnsibleTaggedDict"]}.each do |label, (literal, type_name)|
      out, _ = template_probe("enc-#{label}", "output_encoding: #{literal}\n")
      out.must_include("encode() argument 'encoding' must be str, not #{type_name}")
    end
  end

  it "falls back to utf-8 for a falsy output_encoding instead of failing" do
    {"false" => "false", "zero" => "0", "zero-float" => "0.0",
     "empty-list" => "[]", "null" => ""}.each do |label, literal|
      out, dest = template_probe("enc-falsy-#{label}", "output_encoding: #{literal}\n")
      out.wont_include("ERROR")
      File.read(dest).must_equal("hello\n")
    end
  end

  it "still writes a string output_encoding in that encoding" do
    out, dest = template_probe("enc-latin1", "output_encoding: latin-1\n")
    out.wont_include("ERROR")
    File.read(dest).must_equal("hello\n")
  end

  it "reports an unknown codec from the action plugin, with real's Task failed wrapper" do
    out, _ = template_probe("enc-unknown", "output_encoding: nosuchcodec\n")

    out.must_include("[ERROR]: Task failed: unknown encoding: nosuchcodec")
    out.must_include("\"msg\": \"Task failed: unknown encoding: nosuchcodec\"")
  end
end
