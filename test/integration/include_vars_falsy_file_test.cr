require "../minitest_helper"
require "file_utils"

# include_vars: FREE-FORM value that resolves to a falsy native value
# (issue #850, bodsch.mpd; issue #1085, 5u623l20.pgsql).
#
# bodsch.mpd's `include_vars: "{{ lookup('first_found', params) }}"`
# (skip: true, no candidate on Rocky 9) hands include_vars an empty
# LIST, and 5u623l20.pgsql's identical free-form form does the same on
# any distribution it ships no vars/ file for. Under ansible-core 2.19
# the task-arg templating stringified `_raw_params` ("[]"/"False") and
# the plugin ended in AnsibleFileNotFound's bare "Could not find file"
# head - the shape #850 was fixed against. 2.21's templating keeps the
# native value, so _set_args' falsy branch leaves the list/bool itself in
# source_file and _find_needle dies in os.path.join; a TRUTHY non-string
# dies one line earlier on _set_args' own .rstrip('\n').
# Live-verified vs 2.21.6 (free-form _raw_params form):
#   {{ lookup('first_found', params) }} (skip, no match) -> join()
#     argument must be str, bytes, or os.PathLike object, not
#     '_AnsibleTaggedList'
#   {{ false }} -> join() argument must be str, bytes, or os.PathLike
#     object, not 'bool'
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_falsy_include_vars(playbook : String) : String
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, input: IO::Memory.new, chdir: File.dirname(playbook))
  raise "playbook failed with rc=#{status.exit_code}:\n#{output}" unless status.success?
  output.to_s
end

private def falsy_include_vars_error(output : String) : String
  line = output.each_line.find { |text_line| text_line.starts_with?("[ERROR]: Task failed: ") }
  raise "no [ERROR] line in output:\n#{output}" unless line
  line.sub("[ERROR]: Task failed: ", "")
end

describe "include_vars free-form value resolving to a falsy native value" do
  it "crashes an empty first_found skip result in os.path.join, like _find_needle" do
    src_dir = File.tempname("include-vars-falsy")
    Dir.mkdir_p(File.join(src_dir, "vars"))
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: true
        connection: local
        tasks:
          - name: include os specific vars
            ansible.builtin.include_vars: "{{ lookup('first_found', params) }}"
            vars:
              params:
                paths:
                  - "vars"
                files:
                  - "krikri-nomatch-{{ ansible_facts.distribution | lower }}.yml"
                  - "default.yaml"
                skip: true
            ignore_errors: true
      YAML

    output = run_falsy_include_vars(File.join(src_dir, "pb.yml"))
    falsy_include_vars_error(output).must_equal(
      "join() argument must be str, bytes, or os.PathLike object, not '_AnsibleTaggedList'")
    output.wont_include("Searched in")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "crashes a falsy scalar whole-expression value in os.path.join, like _find_needle" do
    src_dir = File.tempname("include-vars-falsy-scalar")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: falsy scalar file
            ansible.builtin.include_vars: "{{ false }}"
            ignore_errors: true
      YAML

    output = run_falsy_include_vars(File.join(src_dir, "pb.yml"))
    falsy_include_vars_error(output).must_equal(
      "join() argument must be str, bytes, or os.PathLike object, not 'bool'")
    output.wont_include("Searched in")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "keeps the top-level fact read's deprecation on a truthy non-string crash" do
    # The type probe is the only render a crashing value ever gets, so it
    # must be the read that prints the INJECT_FACTS_AS_VARS block - real
    # templating _raw_params prints it once, at the value, and only then
    # dies on .rstrip (live-verified vs 2.21.6).
    src_dir = File.tempname("include-vars-typed-fact")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        gather_facts: true
        connection: local
        tasks:
          - name: truthy non-string fact
            ansible.builtin.include_vars: "{{ ansible_env }}"
            ignore_errors: true
      YAML

    output = run_falsy_include_vars(File.join(src_dir, "pb.yml"))
    falsy_include_vars_error(output).must_equal(
      "'_AnsibleTaggedDict' object has no attribute 'rstrip'")
    output.scan(/INJECT_FACTS_AS_VARS/).size.must_equal(1)
    output.must_include("Origin: #{src_dir}/pb.yml:")
    output.wont_include("Searched in")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
