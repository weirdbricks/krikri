require "../spec_helper"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "htpasswd plugin" do
  it "creates the file and adds a user with an apr1 hash" do
    path = tmp_path("htpasswd-create")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should start_with("johndoe:$apr1$")
  end

  it "is idempotent when the password is unchanged" do
    path = tmp_path("htpasswd-idempotent")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})

    result["changed"].as_bool.should be_false
  end

  it "updates the hash when the password changes" do
    path = tmp_path("htpasswd-update")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})
    first_hash = File.read(path).split(':', 2)[1]

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "different"})

    result["changed"].as_bool.should be_true
    File.read(path).split(':', 2)[1].should_not eq(first_hash)
  end

  it "preserves other users' entries when adding a new one" do
    path = tmp_path("htpasswd-multi")
    File.delete(path) if File.exists?(path)
    PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure"})

    PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "janedoe", "password" => "othersecret"})

    content = File.read(path)
    content.should contain("johndoe:")
    content.should contain("janedoe:")
  end

  it "removes a user when state=absent" do
    path = tmp_path("htpasswd-remove")
    File.write(path, "johndoe:$apr1$abc$xyz\njanedoe:$apr1$abc$xyz\n")

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "state" => "absent"})

    result["changed"].as_bool.should be_true
    content = File.read(path)
    content.should_not contain("johndoe:")
    content.should contain("janedoe:")
  end

  it "no-ops removing a user that's already absent" do
    path = tmp_path("htpasswd-remove-noop")
    File.write(path, "janedoe:$apr1$abc$xyz\n")

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "state" => "absent"})

    result["changed"].as_bool.should be_false
  end

  it "supports crypt_scheme: plaintext" do
    path = tmp_path("htpasswd-plaintext")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "foo", "password" => "bar", "crypt_scheme" => "plaintext"})

    result["changed"].as_bool.should be_true
    File.read(path).should eq("foo:bar\n")
  end

  it "does not write to disk in check mode" do
    path = tmp_path("htpasswd-check-mode")
    File.delete(path) if File.exists?(path)

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "supersecure", "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    File.exists?(path).should be_false
  end

  it "fails with a clear message when path is missing" do
    result = PluginSpecHelper.run("htpasswd", {"name" => "johndoe", "password" => "supersecure"})

    result["failed"].as_bool.should be_true
  end

  it "fails with a clear message for an unsupported crypt_scheme" do
    path = tmp_path("htpasswd-bad-scheme")

    result = PluginSpecHelper.run("htpasswd", {"path" => path, "name" => "johndoe", "password" => "x", "crypt_scheme" => "bcrypt"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("crypt_scheme")
  end
end
