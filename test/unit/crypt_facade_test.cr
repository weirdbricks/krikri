require "../minitest_helper"
require "../../src/krikri/plugin_helpers/crypt_hash"

# The crypt library is loaded at RUNTIME (dlopen), never linked, so these specs
# drive the two degraded shapes real ansible handles the same way: no library at
# all (ansible's "crypt cannot be used..." AnsibleError) and a library without
# crypt_gensalt (musl libc, where ansible builds the salt string by hand).
describe "Krikri::PluginHelpers::CryptHash with no loadable crypt library" do
  exclusive!

  after_each do
    Krikri::PluginHelpers::CryptHash::CryptFacade.current = nil
  end

  it "reports ansible's libxcrypt-missing error" do
    Krikri::PluginHelpers::CryptHash::CryptFacade.current =
      Krikri::PluginHelpers::CryptHash::CryptFacade.new(["libnotacrypt.so.1"])

    assert_raises_message(Exception, "crypt cannot be used as the 'libxcrypt' library is not installed or is unusable.") do
      Krikri::PluginHelpers::CryptHash.hash("hello", "sha512_crypt", "mysalt")
    end
  end

  it "checks the library before the algorithm, like ansible's constructor" do
    Krikri::PluginHelpers::CryptHash::CryptFacade.current =
      Krikri::PluginHelpers::CryptHash::CryptFacade.new(["libnotacrypt.so.1"])

    assert_raises_message(Exception, "crypt cannot be used as the 'libxcrypt' library is not installed or is unusable.") do
      Krikri::PluginHelpers::CryptHash.hash("hello", "no_such_algorithm")
    end
  end
end

describe "Krikri::PluginHelpers::CryptHash without crypt_gensalt (musl libc)" do
  exclusive!

  after_each do
    Krikri::PluginHelpers::CryptHash::CryptFacade.current = nil
  end

  # No glibc host ships a crypt without crypt_gensalt, so the fallback is
  # reached through the facade's own use_gensalt switch rather than by library
  # choice.
  def without_gensalt : Krikri::PluginHelpers::CryptHash::CryptFacade
    facade = Krikri::PluginHelpers::CryptHash::CryptFacade.new(use_gensalt: false)
    skip "no loadable crypt library on this host" unless facade.available?
    Krikri::PluginHelpers::CryptHash::CryptFacade.current = facade
    facade
  end

  it "keeps the salt text verbatim instead of letting libxcrypt re-encode it" do
    without_gensalt

    # libxcrypt's own gensalt would write $6$rounds=656000$hZrQ$... for the
    # salt "mysalt" (see password_hash_sha_crypt_test.cr); the hand-built salt
    # string leaves the text alone, which is what ansible's _build_saltstring
    # does on a musl controller. The hash itself is the same bytes libxcrypt
    # produces for that salt string (live-verified against musl's crypt() in
    # an Alpine container).
    Krikri::PluginHelpers::CryptHash.hash("hello", "sha512_crypt", "mysalt")
      .must_equal("$6$rounds=656000$mysalt$mMWk1/71/712cx6xA3/Cq1qE0R7B2BDA2FPgmbySa7l3J4.y2eYwItEJRJZFDSUdAB3o/rIM.TZR3qDHk9Vp5/")
  end

  it "writes bcrypt's cost as two digits, which musl requires" do
    without_gensalt

    Krikri::PluginHelpers::CryptHash.hash("hello", "bcrypt", "abcdefghijklmnopqrstuv")
      .must_equal("$2b$12$abcdefghijklmnopqrstuuW3FogT0WLDxqwgLK23cI..2q07im5LG")
  end

  it "rejects yescrypt, which needs crypt_gensalt" do
    without_gensalt

    assert_raises_message(Exception, "'yescrypt' algorithm requires libxcrypt") do
      Krikri::PluginHelpers::CryptHash.hash("hello", "yescrypt")
    end
  end
end
