require "../spec_helper"

# Runs the compiled binary against a real playbook (real .j2 template
# rendering via CrinjaRenderer/TemplateActionPlugin), since this bug is
# specifically about the pytruthy rewrite path, not the hand-rolled plain
# {{ }} evaluator.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_template_task(content : String, extra_vars : String = "")
  src = File.tempname("bare-if-undefined-src", ".j2")
  dest = File.tempname("bare-if-undefined-dest")
  playbook = File.tempname("bare-if-undefined", ".yml")
  File.write(src, content)

  File.write(playbook, <<-YAML)
    - name: repro
      hosts: localhost
      gather_facts: false
      #{extra_vars}
      tasks:
        - name: render
          ansible.builtin.template:
            src: #{src}
            dest: #{dest}
    YAML

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s, File.exists?(dest) ? File.read(dest) : nil}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
  File.delete(src) if src && File.exists?(src)
  File.delete(dest) if dest && File.exists?(dest)
end

describe "a bare {% if undefined_var %} condition in a real .j2 template" do
  it "fails the task instead of silently taking the false branch" do
    # Real Ansible's Jinja2 environment (AnsibleUndefined, a
    # StrictUndefined subclass) raises even for a bare boolean condition:
    # verified live against real ansible-playbook via vcc_caeit.ntp's
    # templates/ntp.conf.j2 `{% if ntp_use_external %}` with no default
    # anywhere ("'some_undefined_var' is undefined"). The pytruthy
    # rewrite (TemplateActionPlugin::TAG_IF_ELIF) routes every `{% if %}`
    # through real_truthy?, which used to unconditionally treat ANY
    # undefined - including a StrictUndefined - as falsy, so the task
    # rendered the false branch and reported changed instead of failing.
    status, output, _dest = run_template_task(
      "{% if some_undefined_var %}yes{% else %}no{% endif %}\n",
    )
    status.success?.should be_false
    output.should contain("some_undefined_var")
    output.downcase.should contain("undefined")
  end

  it "still renders the correct branch when the variable is defined (true)" do
    status, output, dest = run_template_task(
      "{% if some_undefined_var %}yes{% else %}no{% endif %}\n",
      "vars:\n    some_undefined_var: true",
    )
    status.success?.should be_true
    dest.should eq("yes\n")
  end

  it "still renders the correct branch when the variable is defined (false)" do
    status, output, dest = run_template_task(
      "{% if some_undefined_var %}yes{% else %}no{% endif %}\n",
      "vars:\n    some_undefined_var: false",
    )
    status.success?.should be_true
    dest.should eq("no\n")
  end

  it "keeps `| default(false)` lenient: takes the false branch, doesn't raise" do
    # The most common real-world guarded idiom - default() only ever
    # tests undefined? and never evaluates the StrictUndefined, exactly
    # as real Jinja2's StrictUndefined permits.
    status, output, dest = run_template_task(
      "{% if some_undefined_var | default(false) %}yes{% else %}no{% endif %}\n",
    )
    status.success?.should be_true
    dest.should eq("no\n")
  end
end
