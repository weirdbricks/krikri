require "../minitest_helper"
require "../../src/krikri/variable_substitutor/expression_evaluator"
require "../../src/krikri/variable_substitutor/jinja_renderer"
# Pull in the Ansible-specific Crinja filter registrations (to_datetime
# etc.), as template_action_plugin.cr does for every real template-rendering
# binary - without this the JinjaRenderer's env has none of them.
require "../../src/krikri/krikri_jinja_filters"

# Ansible's `file` lookup unfracks the term (os.path.expanduser) BEFORE
# searching, so `lookup('file', '~/.ssh/id_rsa.pub')` reads the controller
# user's home dir. krikri skipped that step: a `~/...` term fell through the
# role-relative search and raised "Unable to access the file" (hand-rolled
# evaluator) or returned nil (krikri-jinja path) where ansible-playbook
# reads the file fine (issue #52, andrewrothstein.ssh-user-keygen).
describe "lookup file ~ expansion" do
  serial! # sets/restores HOME (process-wide ENV)

  it "expands a leading ~/ against HOME before the role-relative search, both evaluators" do
    home = PluginSpecHelper.tmp_path("lookup_home_expansion_home")
    Dir.mkdir_p(home)
    File.write(File.join(home, "id_rsa.pub"), "ssh-pubkey-content\n")
    # A role context must not hijack the term: a ~-prefixed path is not a
    # role-relative candidate, so joining <role>/files/~/.ssh/... would be
    # wrong even when role_path happens to be set.
    role_dir = PluginSpecHelper.tmp_path("lookup_home_expansion_role")
    Dir.mkdir_p(File.join(role_dir, "files"))

    original_home = ENV["HOME"]?
    ENV["HOME"] = home
    begin
      v = Hash(String, JSON::Any).new
      v["role_path"] = JSON::Any.new(role_dir)

      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
      evaluator.evaluate(%(lookup('file', '~/id_rsa.pub'))).must_equal("ssh-pubkey-content")

      renderer = Krikri::VariableSubstitutor::JinjaRenderer.new(v)
      renderer.render(%({{ lookup('file', '~/id_rsa.pub') }})).must_equal("ssh-pubkey-content")
    ensure
      original_home ? (ENV["HOME"] = original_home) : ENV.delete("HOME")
    end
  end

  # Bare `~` resolves to the home DIRECTORY, which File.read rejects the
  # same way Ansible's own plugin does - so this level is asserted on the
  # shared helper directly rather than through lookup('file').
  it "expands a bare ~ term, and leaves ~user and plain relative terms alone" do
    home = PluginSpecHelper.tmp_path("lookup_home_expansion_bare")
    Dir.mkdir_p(home)

    original_home = ENV["HOME"]?
    ENV["HOME"] = home
    begin
      Krikri::LookupPlugins.expand_home("~").must_equal(home)
      Krikri::LookupPlugins.expand_home("~/.ssh/id_rsa.pub").must_equal(File.join(home, ".ssh/id_rsa.pub"))
      Krikri::LookupPlugins.expand_home("~other/x").must_equal("~other/x")
      Krikri::LookupPlugins.expand_home("plain/relative.txt").must_equal("plain/relative.txt")
      Krikri::LookupPlugins.expand_home("/abs/path").must_equal("/abs/path")
    ensure
      original_home ? (ENV["HOME"] = original_home) : ENV.delete("HOME")
    end
  end
end
