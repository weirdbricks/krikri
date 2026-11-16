require "../minitest_helper"
require "file_utils"

# community.general.sefcontext declares diff_mode: full and builds its own
# "prepared" diff block for every branch, so a --check --diff run must show
# those lines before the task's status line (issue #1383). The plugin is
# native, so its two module-level import gates and semanage itself are
# stubbed here - the prepared text never depends on a real policy store.
private def sefcontext_diff_env(scratch : String) : Hash(String, String)
  Dir.mkdir_p(scratch)
  python = File.join(scratch, "python3.13")
  File.write(python, "#!/bin/sh\ncase \"$*\" in *sys.executable*) echo /usr/bin/python3.13 ;; esac\nexit 0\n")
  File.chmod(python, 0o755)
  semanage = File.join(scratch, "semanage")
  File.write(semanage, "#!/bin/sh\nexit 0\n")
  File.chmod(semanage, 0o755)
  {"PATH" => "#{scratch}:/nonexistent-sefcontext-diff-probe"}
end

describe "sefcontext plugin - diff mode prepared blocks" do
  it "reports the addition of a path substitution with the module's own wording" do
    env = sefcontext_diff_env(PluginSpecHelper.tmp_path("sefcontext-diff-sub"))

    result = PluginSpecHelper.run("sefcontext",
      {"target" => "defaub", "substitute" => "nmgmed", "ignore_selinux_state" => "true",
       "_ansible_check_mode" => "true", "_ansible_diff" => "true"},
      env: env)

    result["changed"].as_bool.must_equal(true)
    result["diff"]["prepared"].as_s.must_equal(
      "# Addition to semanage file context path substitutions\n+defaub = nmgmed\n")
  end

  it "reports the addition of a file context mapping with the module's own wording" do
    env = sefcontext_diff_env(PluginSpecHelper.tmp_path("sefcontext-diff-fcontext"))

    result = PluginSpecHelper.run("sefcontext",
      {"target" => "/srv/x(/.*)?", "setype" => "httpd_t", "ignore_selinux_state" => "true",
       "_ansible_check_mode" => "true", "_ansible_diff" => "true"},
      env: env)

    result["changed"].as_bool.must_equal(true)
    result["diff"]["prepared"].as_s.must_equal(
      "# Addition to semanage file context mappings\n+/srv/x(/.*)?      a      system_u:object_r:httpd_t:s0\n")
  end

  it "omits the diff unless diff mode is on" do
    env = sefcontext_diff_env(PluginSpecHelper.tmp_path("sefcontext-diff-off"))

    result = PluginSpecHelper.run("sefcontext",
      {"target" => "defaub", "substitute" => "nmgmed", "ignore_selinux_state" => "true",
       "_ansible_check_mode" => "true"},
      env: env)

    result["changed"].as_bool.must_equal(true)
    result["diff"]?.must_be_nil
  end
end
