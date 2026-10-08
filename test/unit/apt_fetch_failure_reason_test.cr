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
#   repository-level errors - a signature that can't be verified
#   ("W: GPG error ... NO_PUBKEY ...", "E: The repository ... is not
#   signed."). str() is the W:/E: diagnostic lines, marker-space
#   stripped, ", "-joined; from the second failed attempt on, apt
#   prepends its two untrusted-repo lines. Round 5210000
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

private BARE_FETCH_RESULT = {
  exit_code: 0,
  stdout:    "Err:2 http://bogus.invalid/ubuntu jammy InRelease\n  Could not resolve host\n",
  stderr:    "W: Failed to fetch http://bogus.invalid/ubuntu jammy InRelease\nW: Some index files failed to download. They have been ignored, or old ones used instead.\n",
}

describe Krikri::AptLockRetry do
  describe "#apt_fetch_signature_failure?" do
    it "detects the GPG/unsigned-repo shape" do
      Krikri::AptLockRetryTestProbe.new.apt_fetch_signature_failure?(GPG_RESULT).must_equal(true)
    end

    it "does not classify a plain fetch failure as signature-shaped" do
      Krikri::AptLockRetryTestProbe.new.apt_fetch_signature_failure?(BARE_FETCH_RESULT).must_equal(false)
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

    it "keeps the empty-reason bare-exception shape" do
      harness = FetchRetryHarness.new
      outcome = harness.run(2, 0, BARE_FETCH_RESULT)
      outcome[:recovered].must_equal(false)
      outcome[:warnings][0].must_equal("Failed to update cache after 1 retries due to , retrying")
      outcome[:warnings][2].must_equal("Failed to update cache after 2 retries due to , retrying")
      outcome[:last_reason].must_equal("")
    end
  end
end

# The AptLockRetry methods are mixed into AptPlugin (whose entry point
# this file must not fire); a bare includer exposes them for direct calls.
class Krikri::AptLockRetryTestProbe
  include Krikri::AptLockRetry
end
