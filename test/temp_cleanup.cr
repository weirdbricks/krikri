require "file_utils"

# Specs build scratch paths under Dir.tempdir (File.tempname, File.tempfile and hand-written
# File.join(Dir.tempdir, "name-#{random}")) and rarely remove them, so each run left hundreds of
# entries in /tmp (a tmpfs). Point TMPDIR at a private directory for the whole run and remove it
# at exit; this also covers the child processes the specs spawn. This file must be required before
# minitest/autorun: at_exit handlers run in reverse order, so ours then runs after the tests.
module TempCleanup
  ROOT = begin
    dir = File.tempname("krikri-spec-tmp")
    Dir.mkdir_p(dir)
    ENV["TMPDIR"] = dir
    dir
  end
end

at_exit { FileUtils.rm_rf(TempCleanup::ROOT) }
