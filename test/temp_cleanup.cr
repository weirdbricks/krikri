require "file_utils"

# Every spec makes scratch paths with File.tempname / File.tempfile and the stdlib never removes them,
# so each run left hundreds of entries in /tmp (a tmpfs). Record them here and remove them when the
# process ends. This file must be required before minitest/autorun: at_exit handlers run in reverse
# order, so ours then runs after minitest has run the tests.
module TempCleanup
  PATHS = [] of String

  def self.track(path : String) : String
    PATHS << path
    path
  end

  def self.sweep : Nil
    PATHS.each { |path| FileUtils.rm_rf(path) }
  end
end

at_exit { TempCleanup.sweep }

class File
  def self.tempname(prefix : String?, suffix : String?, *, dir : String = Dir.tempdir)
    TempCleanup.track(previous_def)
  end

  def self.tempfile(prefix : String?, suffix : String?, *, dir : String = Dir.tempdir, encoding = nil, invalid = nil)
    file = previous_def
    TempCleanup.track(file.path)
    file
  end
end
