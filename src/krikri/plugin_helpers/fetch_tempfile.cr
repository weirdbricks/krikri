module Krikri
  module PluginHelpers
    # FetchTempfile - the staged-download tempfile ansible's fetch_file
    # (ansible/module_utils/urls.py) creates:
    #
    #   tempfile.NamedTemporaryFile(dir=module.tmpdir, prefix=file_prefix,
    #                               suffix=file_ext, delete=False)
    #
    # with prefix/suffix from _split_multiext(basename(url), count=2) and
    # the 8-character middle drawn from Python tempfile's
    # _RandomNameSequence charset (lowercase digits and underscore). The
    # staged name is not cosmetic: dnf echoes the file back in its own
    # error text, so issue #818 surfaced ansible's
    # "Public key for epel-release-latest-9.noarch<rand8>.rpm is not
    # installed" against an opaque ".krikri-playbook-rpm-<rand8>.rpm"
    # from a prefix of krikri's own invention. Own file so a spec can
    # require it directly (same shape as MultiextSplit).
    module FetchTempfile
      # The underscore counts: Python's _RandomNameSequence includes it,
      # and krikri-role-tester's rpm-download-tmp mask normalizes exactly
      # this 8-character middle from that charset.
      CHARSET = "abcdefghijklmnopqrstuvwxyz0123456789_"

      # Creates the file (O_EXCL/0600, like Python's mkstemp underneath)
      # in the process temp dir and returns the path. Retries on a
      # collided name; raises when the temp dir itself is unusable.
      def self.create(stem : String, ext : String) : String
        10.times do
          rand_part = String.build(8) do |builder|
            8.times { builder << CHARSET[Random.rand(CHARSET.size)] }
          end
          candidate = File.join(Dir.tempdir, "#{stem}#{rand_part}#{ext}")
          fd = LibC.open(candidate, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL, 0o600)
          next if fd == -1 # typically EEXIST - retry on a fresh name
          LibC.close(fd)
          return candidate
        end
        raise "could not create a unique temp file for #{stem}#{ext} in #{Dir.tempdir}"
      end
    end
  end
end
