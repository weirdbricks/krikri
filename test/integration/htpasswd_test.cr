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
end
