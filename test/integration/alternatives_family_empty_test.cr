require "../minitest_helper"
require "file_utils"

# Debian's `update-alternatives --display` never prints a family, and
# community.general.alternatives stores Python's findall group verbatim
# - "" for the group that never participated, NOT None. The select gate
# is `not (is_same_path or is_same_family)` with is_same_family
# comparing that stored value against the task's `family:` param (None
# when the task gives none): `"" == None` is False, so a task pointing
# the alternative somewhere new DOES run `--set` and reports changed.
# Storing nil instead made nil == nil true and silently skipped the
# select - reported ok where Ansible reported changed (found via
# do1jlr.base's own "vim is our editor" task and
# chusiang.vim-and-vi-mode's "switch default editor to vim", rounds
# 1500247/1500533).
#
# Shim: a stub `update-alternatives` on the PATH answers --display with
# canned Debian-style output (no family lines) and logs every other
# invocation to $KRIKRI_UA_CALLS - no root needed, nothing touched.
# Yields the `_environment` JSON param and the call-log path.
private def with_alternatives_shim(display_output : String, &)
  dir = File.join(Dir.tempdir, "krikri-alternatives-#{Random.rand(1_000_000)}")
  log = File.join(dir, "calls.log")
  FileUtils.mkdir_p(dir)
  shim = <<-'SHIM'
    #!/bin/sh
    case "$1" in
      --display)
        printf '%b' "$KRIKRI_UA_DISPLAY"
        exit 0
        ;;
      *)
        echo "$@" >> "$KRIKRI_UA_CALLS"
        exit 0
        ;;
    esac
    SHIM
  File.write(File.join(dir, "update-alternatives"), shim)
  File.chmod(File.join(dir, "update-alternatives"), 0o755)
  env = {
    "PATH"             => "#{dir}:/usr/bin:/bin",
    "KRIKRI_UA_CALLS"  => log,
    "KRIKRI_UA_DISPLAY" => display_output,
  }.to_json
  yield env, log
ensure
  FileUtils.rm_rf(dir) if dir
end

# Debian-style editor group: current link on vim.tiny, vim.basic already
# registered (the state a fresh Ubuntu host is in right after the role
# installs vim).
private def debian_display_output : String
  "editor - auto mode\n" \
  "  link currently points to /usr/bin/vim.tiny\n" \
  "/etc/alternatives/editor - priority 10\n" \
  "  slave editor.1.gz: /usr/share/man/man1/editor.1.gz\n" \
  "/usr/bin/vim.tiny - priority 10\n" \
  "  slave editor.1.gz: /usr/share/man/man1/vim.tiny.1.gz\n" \
  "/usr/bin/vim.basic - priority 50\n" \
  "  slave editor.1.gz: /usr/share/man/man1/vim.1.gz\n"
end

describe "alternatives Debian family parsing" do
  it "runs --set when the current link points elsewhere, even without family: on either side" do
    with_alternatives_shim(debian_display_output) do |env, log|
      result = PluginSpecHelper.run("alternatives", {
        "name"         => "editor",
        "path"         => "/usr/bin/vim.basic",
        "_environment" => env,
      })

      result["changed"].as_bool.must_equal(true)
      File.read(log).must_include("--set editor /usr/bin/vim.basic")
      # The already-registered path is not reinstalled (real's
      # install() gate is `path not in current_alternatives`).
      File.read(log).wont_include("--install")
    end
  end

  it "reports ok when the current link already points at the requested path" do
    output = debian_display_output.gsub("link currently points to /usr/bin/vim.tiny",
      "link currently points to /usr/bin/vim.basic")
    with_alternatives_shim(output) do |env, log|
      result = PluginSpecHelper.run("alternatives", {
        "name"         => "editor",
        "path"         => "/usr/bin/vim.basic",
        "_environment" => env,
      })

      result["changed"].as_bool.must_equal(false)
      File.exists?(log).must_equal(false)
    end
  end
end
