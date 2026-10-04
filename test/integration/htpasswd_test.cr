require "../minitest_helper"

# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead and the
# before_suite body is folded into the helper itself.
describe "htpasswd plugin" do
  it "creates the file and adds a user with an apr1 hash" do
    path = PluginSpecHelper.tmp_path("htpasswd-create")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    expect(str_starts_with?(content, "johndoe:$apr1$")).must_equal(true)
  end

  it "is idempotent when the password is unchanged" do
    path = PluginSpecHelper.tmp_path("htpasswd-idempotent")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})

    result["changed"].as_bool.must_equal(false)
  end

  it "updates the hash when the password changes" do
    path = PluginSpecHelper.tmp_path("htpasswd-update")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})
    first_hash = File.read(path).split(':', 2)[1]

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "different"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).split(':', 2)[1].wont_equal(first_hash)
  end

  it "preserves other users' entries when adding a new one" do
    path = PluginSpecHelper.tmp_path("htpasswd-multi")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})

    PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "janedoe", "password" => "othersecret"})

    content = File.read(path)
    content.must_include("johndoe:")
    content.must_include("janedoe:")
  end

  it "removes a user when state=absent" do
    path = PluginSpecHelper.tmp_path("htpasswd-remove")
    File.write(path, "johndoe:$apr1$abc$xyz\njanedoe:$apr1$abc$xyz\n")

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "state" => "absent"})

    result["changed"].as_bool.must_equal(true)
    content = File.read(path)
    content.wont_include("johndoe:")
    content.must_include("janedoe:")
  end

  it "no-ops removing a user that's already absent" do
    path = PluginSpecHelper.tmp_path("htpasswd-remove-noop")
    File.write(path, "janedoe:$apr1$abc$xyz\n")

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "state" => "absent"})

    result["changed"].as_bool.must_equal(false)
  end

  it "supports crypt_scheme: plaintext" do
    path = PluginSpecHelper.tmp_path("htpasswd-plaintext")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "foo", "password" => "bar", "crypt_scheme" => "plaintext"})

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("foo:bar\n")
  end

  it "does not write to disk in check mode" do
    path = PluginSpecHelper.tmp_path("htpasswd-check-mode")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    File.exists?(path).must_equal(false)
  end

  it "fails with a clear message when path is missing" do
    result = PluginSpecHelper.run("htpasswd", {"name" => "johndoe", "password" => "supersecure"})

    result["failed"].as_bool.must_equal(true)
  end

  it "fails with a clear message for an unsupported crypt_scheme" do
    path = PluginSpecHelper.tmp_path("htpasswd-bad-scheme")

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "x", "crypt_scheme" => "bcrypt"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("crypt_scheme")
  end

  # Regression spec for the ad-hoc CLI sweep (2026-09-13): the first (create)
  # call used to say "Updating user X"; real community.general.htpasswd
  # branches the msg on whether the call actually created the file
  # ("Created {path} and added {user}") versus changed an existing one
  # ("Add/update {user}"), verified live.
  it "says \"Created <path> and added <user>\" on a brand-new file" do
    path = PluginSpecHelper.tmp_path("htpasswd-create-msg")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Created #{path} and added johndoe")
  end

  it "says \"Add/update <user>\" when changing an existing file's user" do
    path = PluginSpecHelper.tmp_path("htpasswd-update-msg")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "different"})

    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Add/update johndoe")
  end

  it "says \"<user> already present\" when the password matches" do
    path = PluginSpecHelper.tmp_path("htpasswd-idempotent-msg")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("johndoe already present")
  end

  # kpg32 seed 32: every one of the sweep's htpasswd playbooks passed a
  # scheme name real's passlib does not know. Real's message is the
  # passlib CryptContext ValueError, whose str() carries the algorithm
  # name in single quotes inside the module's own double quotes.
  it "reports an unknown hash_scheme exactly like passlib's CryptContext" do
    path = PluginSpecHelper.tmp_path("htpasswd-unknown-scheme")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("htpasswd", {
      "path" => path, "name" => "johndoe", "password" => "x", "hash_scheme" => "nosuchscheme",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(%("no crypt handler found for algorithm: 'nosuchscheme'"))
  end

  it "reports real's passlib None-secret error for state=present without a password" do
    path = PluginSpecHelper.tmp_path("htpasswd-no-password")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("secret must be unicode or bytes, not None")
  end

  it "does not validate hash_scheme for state=absent, like real's absent()" do
    path = PluginSpecHelper.tmp_path("htpasswd-absent-bad-scheme")
    File.write(path, "johndoe:hash\n")

    result = PluginSpecHelper.run("htpasswd", {
      "path" => path, "name" => "johndoe", "state" => "absent", "hash_scheme" => "nosuchscheme",
    })

    result["failed"]?.try(&.as_bool).must_be_nil
    result["changed"].as_bool.must_equal(true)
  end

  it "reports real's IsADirectoryError when path: is a directory" do
    dir = PluginSpecHelper.tmp_path("htpasswd-a-directory")
    Dir.mkdir_p(dir)

    result = PluginSpecHelper.run("htpasswd", {"path" => dir, "name" => "johndoe", "password" => "x"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("[Errno 21] Is a directory: '#{dir}'")
  end

  it "words the create=false failure like real's present() ValueError" do
    path = PluginSpecHelper.tmp_path("htpasswd-create-false")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("htpasswd", {
      "path" => path, "name" => "johndoe", "password" => "x", "create" => "false",
    })

    result["msg"].as_s.must_equal("Destination #{path} does not exist")
  end

  it "says \"Remove <user>\" on an absent removal, like real's absent()" do
    path = PluginSpecHelper.tmp_path("htpasswd-remove-msg")
    File.write(path, "johndoe:hash\n")

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "state" => "absent"})

    result["msg"].as_s.must_equal("Remove johndoe")
  end

  # ldap_sha1 is one of the four apache_hashes passlib's htpasswd
  # context always carries, so real accepts it everywhere - and being
  # unsalted it is the one non-plaintext scheme computable without
  # shelling out at all.
  it "hashes with ldap_sha1, one of passlib's apache_hashes" do
    path = PluginSpecHelper.tmp_path("htpasswd-ldap-sha1")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("htpasswd", {
      "path" => path, "name" => "johndoe", "password" => "pw", "hash_scheme" => "ldap_sha1",
    })

    result["changed"].as_bool.must_equal(true)
    File.read(path).must_equal("johndoe:{SHA}GpHWL3ymc5liWkNopqtdSjuqYHM=\n")
  end

  # The crypt schemes' random salt must keep the exact shape the schemes
  # define (sha512_crypt: 16 chars from the crypt alphabet) - the hash is
  # only ever verified by recomputing with the salt extracted from the
  # stored line, so the shape is the observable contract.
  it "generates a sha512_crypt salt of the right shape" do
    path = PluginSpecHelper.tmp_path("htpasswd-salt-shape")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("htpasswd", {
      "path" => path, "name" => "johndoe", "password" => "pw", "hash_scheme" => "sha512_crypt",
    })

    result["changed"].as_bool.must_equal(true)
    hash = File.read(path).strip.split(":")[1]
    hash.starts_with?("$6$").must_equal(true)
    salt = hash["$6$".size..].split("$").first
    salt.size.must_equal(16)
    salt.each_char.all? { |c| "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".includes?(c) }.must_equal(true)
  end

  # Two fresh hashes of the same password must not reuse a salt: the salt
  # comes from Random::Secure, so identical consecutive salts are
  # astronomically unlikely (64^16 space).
  it "does not reuse the same random salt across runs" do
    salts = 2.times.map do |i|
      path = PluginSpecHelper.tmp_path("htpasswd-salt-fresh-#{i}")
      File.delete(path) if File.exists?(path)
      PluginSpecHelper.run("htpasswd", {
        "path" => path, "name" => "johndoe", "password" => "pw", "hash_scheme" => "sha512_crypt",
      })
      salt = File.read(path).strip.split(":")[1]["$6$".size..].split("$").first
      File.delete(path)
      salt
    end.to_a

    (salts[0] != salts[1]).must_equal(true)
  end
end
