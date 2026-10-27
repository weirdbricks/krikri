require "../../src/krikri/plugin_helpers/apt_lock_retry"
require "../minitest_helper"

# Regression specs for the python-apt FetchFailedException classification
# shared by the apt and apt_repository plugins' update-cache retry loops.
#
# python-apt raises FetchFailedException two ways (verified live in a
# jammy 22.04 container against ansible-core and python3-apt):
# - BARE `FetchFailedException()` for plain network fetch failures -
#   str() empty, so retry warnings and the final msg carry NO reason
#   (round 1100002's verified shape).
# - `FetchFailedException(e)` wrapping apt_pkg's SystemError for
#   repository-level errors ("E: The repository ... is not signed.",
#   other top-level E: diagnostics). A standalone "W: GPG error ...
#   NO_PUBKEY ..." warning is NOT one of them: python-apt raises only on
#   a failed item, so a warning-only update exits 0 and succeeds. str()
#   is the W:/E: diagnostic lines, marker-space stripped, ", "-joined;
#   from the second failed attempt on, apt prepends its two
#   untrusted-repo lines. Round 5210000
#   (artem_shestakov.nginx): real ansible-core 2.19.11 warned five
#   times with this text and failed with "Failed to update apt cache
#   after 5 retries: W:..., E:..." while krikri classified the case as
#   a plain nonzero-exit failure and failed fast with none of it.
private class FetchRetryHarness
  include Krikri::AptLockRetry

  getter calls : Array(String) = [] of String

  def run(retries : Int32, max_delay : Int32, result,
          initial_reason : String = "", initial_signature_failed : Bool = false)
    exec = ->(command : String) {
      @calls << command
      result
    }
    apt_fetch_failed_update_retry(retries, max_delay, exec,
      initial_reason: initial_reason, initial_signature_failed: initial_signature_failed)
  end
end

private GPG_RESULT = {
  exit_code: 0,
  stdout:    "Hit:1 http://archive.ubuntu.com/ubuntu jammy InRelease\nErr:3 https://nginx.org/packages/ubuntu jammy InRelease\n  The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 2FD21310B49F6B46\n",
  stderr:    "W: GPG error: https://nginx.org/packages/ubuntu jammy InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 2FD21310B49F6B46\nE: The repository 'https://nginx.org/packages/ubuntu jammy InRelease' is not signed.\n",
}

private GPG_WARNING_ONLY_RESULT = {
  exit_code: 0,
  stdout:    "",
  stderr:    "W: GPG error: https://mirror.rackspace.com/mariadb/mariadb-11.8.9/repo/ubuntu jammy InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY F1656F24C74CD1D8\n",
}

private UNSIGNED_WARNING_RESULT = {
  exit_code: 0,
  stdout:    "",
  stderr:    "W: The repository 'file:/srv/r ./ Release' is not signed.\nW: No Hash entry in Release file /var/lib/apt/lists/_srv_r_._Release\n",
}

private BARE_FETCH_RESULT = {
  exit_code: 0,
  stdout:    "Err:2 http://bogus.invalid/ubuntu jammy InRelease\n  Could not resolve host\n",
  stderr:    "W: Failed to fetch http://bogus.invalid/ubuntu jammy InRelease\nW: Some index files failed to download. They have been ignored, or old ones used instead.\n",
}

# xe0nic.ansible_vprotect_server: a mixed GPG-warning + 404 update
# failure exactly as apt's CLI prints it.
private VPROTECT_STDERR = "W: GPG error: https://mirror.rackspace.com/mariadb/mariadb-11.8.9/repo/ubuntu jammy InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY F1656F24C74CD1D8\nE: Failed to fetch http://repo.storware.eu/storware/current/el22/./Packages  404  Not Found [IP: 46.174.177.28 80]\nE: Some index files failed to download. They have been ignored, or old ones used instead.\n"

private VPROTECT_RESULT = {
  exit_code: 0,
  stdout:    "",
  stderr:    VPROTECT_STDERR,
}

# Three GPG-broken repositories, the round-29883431 amottier.debian_minimal
# shape (issue #408): the CLI stderr carries one "W: GPG error ..." +
# "E: ... is not signed." block per repo with no untrusted-repo lines.
private MULTI_GPG_RESULT = {
  exit_code: 0,
  stdout:    "",
  stderr:    "W: GPG error: https://deb.debian.org/debian trixie InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 6ED0E7B82643E131 NO_PUBKEY 78DBA3BC47EF2265 NO_PUBKEY 762F67A0B2C39DE4\nE: The repository 'https://deb.debian.org/debian trixie InRelease' is not signed.\nW: GPG error: https://security.debian.org/debian-security trixie-security InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY BDE6D2B9216EC7A8 NO_PUBKEY 8E9F831205B4BA95\nE: The repository 'https://security.debian.org/debian-security trixie-security InRelease' is not signed.\nW: GPG error: https://deb.debian.org/debian trixie-updates InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 6ED0E7B82643E131 NO_PUBKEY 78DBA3BC47EF2265\nE: The repository 'https://deb.debian.org/debian trixie-updates InRelease' is not signed.\n",
}

private def multi_gpg_blocks : Array(String)
  [
    "W:GPG error: https://deb.debian.org/debian trixie InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 6ED0E7B82643E131 NO_PUBKEY 78DBA3BC47EF2265 NO_PUBKEY 762F67A0B2C39DE4",
    "E:The repository 'https://deb.debian.org/debian trixie InRelease' is not signed.",
    "W:GPG error: https://security.debian.org/debian-security trixie-security InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY BDE6D2B9216EC7A8 NO_PUBKEY 8E9F831205B4BA95",
    "E:The repository 'https://security.debian.org/debian-security trixie-security InRelease' is not signed.",
    "W:GPG error: https://deb.debian.org/debian trixie-updates InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 6ED0E7B82643E131 NO_PUBKEY 78DBA3BC47EF2265",
    "E:The repository 'https://deb.debian.org/debian trixie-updates InRelease' is not signed.",
  ]
end

private def multi_gpg_separated_reason : String
  pair = Krikri::AptLockRetry::APT_FETCH_SECURE_REPO_PREPEND
  blocks = multi_gpg_blocks
  [blocks[0], blocks[1], pair, blocks[2], blocks[3], pair, blocks[4], blocks[5]].join(", ")
end

describe Krikri::AptLockRetry do
  describe "#apt_fetch_signature_failure?" do
    it "detects the GPG/unsigned-repo shape" do
      Krikri::AptLockRetryTestProbe.new.apt_fetch_signature_failure?(GPG_RESULT).must_equal(true)
    end

    it "does not classify a plain fetch failure as signature-shaped" do
      Krikri::AptLockRetryTestProbe.new.apt_fetch_signature_failure?(BARE_FETCH_RESULT).must_equal(false)
    end

    it "ignores the allow-insecure W: unsigned-repo warning" do
      probe = Krikri::AptLockRetryTestProbe.new
      probe.apt_fetch_signature_failure?(UNSIGNED_WARNING_RESULT).must_equal(false)
      probe.apt_fetch_failed?(UNSIGNED_WARNING_RESULT).must_equal(false)
    end

    it "ignores a standalone GPG warning with no failed item" do
      probe = Krikri::AptLockRetryTestProbe.new
      probe.apt_fetch_signature_failure?(GPG_WARNING_ONLY_RESULT).must_equal(false)
      probe.apt_fetch_failed?(GPG_WARNING_ONLY_RESULT).must_equal(false)
    end
  end

  describe "#apt_fetch_failure_reason" do
    it "extracts the W:/E: lines python-apt puts in the exception text" do
      probe = Krikri::AptLockRetryTestProbe.new
      probe.apt_fetch_failure_reason(GPG_RESULT).must_equal(
        "W:GPG error: https://nginx.org/packages/ubuntu jammy InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 2FD21310B49F6B46, E:The repository 'https://nginx.org/packages/ubuntu jammy InRelease' is not signed."
      )
    end

    it "stays empty for the bare-exception class" do
      Krikri::AptLockRetryTestProbe.new.apt_fetch_failure_reason(BARE_FETCH_RESULT).must_equal("")
    end

    it "returns the vprotect repo's W:/E: lines unchanged, with no untrusted-repo prefix" do
      Krikri::AptLockRetryTestProbe.new.apt_fetch_failure_reason(VPROTECT_RESULT).must_equal(
        "W:GPG error: https://mirror.rackspace.com/mariadb/mariadb-11.8.9/repo/ubuntu jammy InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY F1656F24C74CD1D8, E:Failed to fetch http://repo.storware.eu/storware/current/el22/./Packages  404  Not Found [IP: 46.174.177.28 80], E:Some index files failed to download. They have been ignored, or old ones used instead."
      )
    end

    # python-apt separates each failed repository's GPG block with its
    # two untrusted-repo lines (probed live in a trixie container,
    # issue #408) - the CLI stderr carries none of them
    it "separates each failed repo's GPG block with the untrusted-repo pair" do
      Krikri::AptLockRetryTestProbe.new.apt_fetch_failure_reason(MULTI_GPG_RESULT).must_equal(multi_gpg_separated_reason)
    end

    it "keeps a single GPG block bare without the untrusted-repo pair" do
      Krikri::AptLockRetryTestProbe.new.apt_fetch_failure_reason(GPG_RESULT).must_equal(
        "W:GPG error: https://nginx.org/packages/ubuntu jammy InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 2FD21310B49F6B46, E:The repository 'https://nginx.org/packages/ubuntu jammy InRelease' is not signed."
      )
    end
  end

  describe "#apt_fetch_attempt_reason" do
    it "quotes the first failed attempt's text bare and flips the flag only for later attempts" do
      probe = Krikri::AptLockRetryTestProbe.new
      reason = Krikri::AptLockRetryTestProbe.new.apt_fetch_failure_reason(GPG_RESULT)

      first = probe.apt_fetch_attempt_reason(reason, false)
      first[0].must_equal(reason)
      first[1].must_equal(true)

      second = probe.apt_fetch_attempt_reason(reason, first[1])
      second[0].must_equal("#{Krikri::AptLockRetry::APT_FETCH_SECURE_REPO_PREPEND}, #{reason}")
      second[1].must_equal(true)
    end

    it "keeps the bare-exception class empty and the flag untouched" do
      probe = Krikri::AptLockRetryTestProbe.new
      outcome = probe.apt_fetch_attempt_reason("", false)
      outcome[0].must_equal("")
      outcome[1].must_equal(false)
    end
  end

  describe "#apt_fetch_failed_update_retry" do
    it "quotes the failed attempt's exception text in the warnings and final reason" do
      harness = FetchRetryHarness.new
      outcome = harness.run(2, 0, GPG_RESULT,
        initial_reason: Krikri::AptLockRetryTestProbe.new.apt_fetch_failure_reason(GPG_RESULT),
        initial_signature_failed: true)
      outcome[:recovered].must_equal(false)
      outcome[:warnings][0].must_equal("Failed to update cache after 1 retries due to W:GPG error: https://nginx.org/packages/ubuntu jammy InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 2FD21310B49F6B46, E:The repository 'https://nginx.org/packages/ubuntu jammy InRelease' is not signed., retrying")
      # the backoff delay carries a random jitter, so only the wording is pinned
      outcome[:warnings][1].starts_with?("Sleeping for ").must_equal(true)
      outcome[:warnings][1].ends_with?(" seconds, before attempting to refresh the cache again").must_equal(true)
      # from the second failed attempt on, apt prepends the two
      # untrusted-repo diagnostic lines to the exception text
      outcome[:warnings][2].starts_with?("Failed to update cache after 2 retries due to W:Updating from such a repository can't be done securely").must_equal(true)
      outcome[:last_reason].starts_with?("W:Updating from such a repository can't be done securely").must_equal(true)
    end

    it "recovers on a GPG-warning-only update that exits 0" do
      harness = FetchRetryHarness.new
      outcome = harness.run(2, 0, GPG_WARNING_ONLY_RESULT)
      outcome[:recovered].must_equal(true)
      outcome[:last_reason].must_equal("")
    end

    it "recovers on the allow-insecure W: unsigned-repo warning with no retry" do
      harness = FetchRetryHarness.new
      outcome = harness.run(2, 0, UNSIGNED_WARNING_RESULT)
      outcome[:recovered].must_equal(true)
      harness.calls.size.must_equal(1)
    end

    it "keeps the empty-reason bare-exception shape" do
      harness = FetchRetryHarness.new
      outcome = harness.run(2, 0, BARE_FETCH_RESULT)
      outcome[:recovered].must_equal(false)
      outcome[:warnings][0].must_equal("Failed to update cache after 1 retries due to , retrying")
      outcome[:warnings][2].must_equal("Failed to update cache after 2 retries due to , retrying")
      outcome[:last_reason].must_equal("")
    end

    # Multi-repo shape (issue #408): every attempt's text is the
    # block-per-repo reason with the untrusted-repo pair between the
    # blocks, and from the second failed attempt on the pair is ALSO
    # prepended once - live-verified against ansible-core 2.19.11 on a
    # GPG-broken trixie container (attempt 1 quoted two pairs, attempts
    # 2+ quoted three, one before each repo's block)
    it "quotes the multi-repo separated reason bare, then with the prepend" do
      probe = Krikri::AptLockRetryTestProbe.new
      reason = probe.apt_fetch_failure_reason(MULTI_GPG_RESULT)
      reason.must_equal(multi_gpg_separated_reason)

      harness = FetchRetryHarness.new
      outcome = harness.run(2, 0, MULTI_GPG_RESULT,
        initial_reason: reason,
        initial_signature_failed: true)
      outcome[:recovered].must_equal(false)
      outcome[:warnings][0].must_equal("Failed to update cache after 1 retries due to #{reason}, retrying")
      outcome[:warnings][2].must_equal("Failed to update cache after 2 retries due to #{Krikri::AptLockRetry::APT_FETCH_SECURE_REPO_PREPEND}, #{reason}, retrying")
      outcome[:last_reason].must_equal("#{Krikri::AptLockRetry::APT_FETCH_SECURE_REPO_PREPEND}, #{reason}")
    end
  end
end

# The AptLockRetry methods are mixed into AptPlugin (whose entry point
# this file must not fire); a bare includer exposes them for direct calls.
class Krikri::AptLockRetryTestProbe
  include Krikri::AptLockRetry
end
