require "../minitest_helper"

# Runs the compiled binary against a real playbook (real .j2 template
# rendering via TemplateActionPlugin's krikri-jinja engine), since the
# failure shape is the action plugin's crash reporting, not the engine's
# own exception text.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "a {% for %} loop over a defined-but-null variable" do
  it "fails with real Ansible's NoneType iteration crash, cause pointed at the template file" do
    # Issue #274: ansible-core 2.19.11 fails a template iterating a var
    # set to YAML null (`al:` with no value) with an UNCAUGHT Python
    # TypeError - "Task failed: Error rendering template: 'NoneType'
    # object is not iterable", the [ERROR] block's <<< caused by >>>
    # cause carrying the template FILE's own Origin - while krikri used
    # to die with the generic rendered failure ("Failed to render
    # template: line 2: Nil is not iterable", engine's Crystal class
    # name leaking into the message).
    src = File.tempname("for-loop-null-src", ".j2")
    dest = File.tempname("for-loop-null-dest")
    playbook = File.tempname("for-loop-null", ".yml")
    File.write(src, "{% for a in al %}\n {{ a }}\n{% endfor %}\n")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          al:
        tasks:
          - name: render
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    text = output.to_s
    # The [ERROR] block's collapsed header and the caused-by cause stanza
    # (what real prints, byte-verified on the same playbook).
    text.must_include("[ERROR]: Task failed: Error rendering template: 'NoneType' object is not iterable")
    text.must_include("<<< caused by >>>")
    text.must_include("Error rendering template: 'NoneType' object is not iterable\nOrigin: #{src}")
    # The fatal dump keeps the "Task failed: " wrapper.
    text.must_include(%("msg": "Task failed: Error rendering template: 'NoneType' object is not iterable"))
    # The engine's Crystal type name and the old generic wording must not
    # surface anywhere.
    text.wont_include("Nil is not iterable")
    text.wont_include("Failed to render template")
    File.exists?(dest).must_equal(false)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "prints the same [ERROR] block under no_log: true, before the censored fatal line" do
    # Real 2.19.11 prints the full [ERROR] block for a failed no_log
    # task too (the message is ansible-composed from a type name, no
    # task data in it - live-verified on the issue repro), with only the
    # fatal dump censored; krikri's no_log suppression (issue #271's
    # leak control) must lift for this fixed-text failure the same way
    # it already lifts for copy's required-argument texts.
    src = File.tempname("for-loop-null-nolog-src", ".j2")
    dest = File.tempname("for-loop-null-nolog-dest")
    playbook = File.tempname("for-loop-null-nolog", ".yml")
    File.write(src, "{% for a in al %}\n {{ a }}\n{% endfor %}\n")

    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          al:
        tasks:
          - name: render
            no_log: true
            ansible.builtin.template:
              src: #{src}
              dest: #{dest}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(false)
    text = output.to_s
    block_at = text.index("[ERROR]: Task failed: Error rendering template: 'NoneType' object is not iterable")
    censored_at = text.index(%("censored": "the output has been hidden due to the fact that 'no_log: true' was specified for this result"))
    (!!block_at && !!censored_at && block_at < censored_at).must_equal(true)
    text.must_include("Origin: #{src}")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
