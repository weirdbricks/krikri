require "../minitest_helper"

# Regressions in the template ACTION plugin's own render path (the
# Engine#render_string call a `.j2` file goes through), which does not
# have the expression path's JinjaVarResolver:
#   * `omit` was undefined there, so Turgon37.sudoers' _macros.j2 and
#     galaxyproject.slurm's slurm.conf/generic.conf failed with
#     "Failed to render template: line 0: 'omit' is undefined" where
#     ansible-playbook 2.19.11 renders (its own Jinja globals always
#     carry `omit`).
#   * a comment body's apostrophe made krikri-jinja's lexer treat the
#     rest of the comment as an unterminated string, so ableton.sccache's
#     config.j2 failed with `unclosed "{#" tag` where real Jinja2's
#     comment rule (`\{#.*?(?:#\}|\Z)`, DOTALL) closes at the first `#}`.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def render_template(content : String, vars_block : String = "")
  src = File.tempname("template-omit-comment-src", ".j2")
  dest = File.tempname("template-omit-comment-dest")
  playbook = File.tempname("template-omit-comment", ".yml")
  File.write(src, content)
  File.write(playbook, <<-YAML)
    - name: render
      hosts: localhost
      gather_facts: false
      #{vars_block}
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

describe "a .j2 template rendered through the template action plugin" do
  it "resolves the omit global (comparison and bare reference)" do
    status, output, dest = render_template(
      "{% if v != omit %}value={{ v }}{% endif %}[A{{ omit }}B]\n",
      "vars:\n    v: \"{{ nope | default(omit) }}\"",
    )
    status.success?.must_equal(true, output)
    # `v` IS omit, so the branch drops; Ansible drops an omit value out
    # of surrounding text too (`A{{ omit }}B` renders "AB" - live-
    # verified against 2.19.11), never the sentinel marker string.
    dest.must_equal("[AB]\n")
  end

  it "closes a comment at the first #} whatever its body reads" do
    status, output, dest = render_template(<<-TPL)
      {#
         Jinja currently doesn't have a native TOML filter, but TOML and JSON have the same
         string representation.
      #}
      [end]
      TPL
    status.success?.must_equal(true, output)
    output.wont_include("unclosed", output)
    dest.must_equal("[end]\n")
  end

  it "renders jinja2's format filter against keyword arguments" do
    status, output, dest = render_template("{{ '%(version)s-linux' | format(version='1.2.3') }}\n")
    status.success?.must_equal(true, output)
    dest.must_equal("1.2.3-linux\n")
  end
end
