require "../minitest_helper"

# Runs the compiled binary against a real playbook (real .j2 template
# rendering via JinjaRenderer/TemplateActionPlugin), since this bug is
# specifically about the krikri-jinja engine's autoescape-safety Markup
# wrapper reaching the top-level JSON conversion, not the hand-rolled
# plain {{ }} evaluator.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_template_task(content : String, extra_vars : String = "")
  src = File.tempname("markup-safe-src", ".j2")
  dest = File.tempname("markup-safe-dest")
  playbook = File.tempname("markup-safe", ".yml")
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

describe "a template whose whole rendered value is Markup-wrapped (xanmanning.k3s regression)" do
  it "renders a `| safe` value used as the entire template body, instead of crashing" do
    # krikri-jinja wraps a `|safe`-filtered expression in Markup (its
    # autoescape-safety type) regardless of whether autoescape is on -
    # see krikri-jinja's filters.cr. Previously, when that Markup value
    # was the WHOLE template result (not embedded inside a larger
    # string), the engine's top-level JSON conversion had no case for
    # Markup and crashed with "Failed to render template: line 0: value
    # of type KrikriJinja::Markup is not JSON-compatible" - found via
    # xanmanning.k3s's k3s.service.j2 (rounds 979194/986000), where real
    # ansible-playbook 2.19.11 renders the file fine. Fixed in
    # krikri-jinja v0.4.19 by unwrapping Markup to its underlying string
    # in to_json_any, matching real Jinja2 (Markup is-a str).
    status, output, dest = run_template_task(
      "{{ 'ExecStart=/usr/local/bin/k3s server' | safe }}\n",
    )
    status.success?.must_equal(true)
    output.wont_include("is not JSON-compatible")
    dest.must_equal("ExecStart=/usr/local/bin/k3s server\n")
  end

  it "still renders a `| safe` value embedded alongside other text" do
    status, _output, dest = run_template_task(
      "prefix-{{ 'raw&stuff' | safe }}-suffix\n",
    )
    status.success?.must_equal(true)
    dest.must_equal("prefix-raw&stuff-suffix\n")
  end
end
