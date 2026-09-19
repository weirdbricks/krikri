require "../spec_helper"
require "file_utils"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "yum_repository")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

private def repo_path(name : String) : String
  File.join(TMP_DIR, "#{name}.repo")
end

describe "yum_repository plugin" do
  it "writes a .repo file with keys sorted alphabetically and description as the name= field" do
    result = PluginSpecHelper.run("yum_repository", {
      "name"        => "epel",
      "description" => "EPEL YUM repo",
      "baseurl"     => "https://example.com/epel/$releasever/$basearch/",
      "gpgcheck"    => "true",
      "enabled"     => "true",
      "reposdir"    => TMP_DIR,
    })

    result["changed"].as_bool.should be_true
    File.read(repo_path("epel")).should eq(
      "[epel]\n" \
      "baseurl = https://example.com/epel/$releasever/$basearch/\n" \
      "enabled = 1\n" \
      "gpgcheck = 1\n" \
      "name = EPEL YUM repo\n" \
      "\n"
    )
  end

  it "reports changed: false on an idempotent rerun" do
    params = {
      "name"        => "idempotent",
      "description" => "Idempotent Repo",
      "baseurl"     => "https://example.com/repo",
      "reposdir"    => TMP_DIR,
    }
    PluginSpecHelper.run("yum_repository", params)

    result = PluginSpecHelper.run("yum_repository", params)

    result["changed"].as_bool.should be_false
  end

  it "regenerates the section from scratch each run, dropping keys not passed this time (matches real ansible-playbook, not a bug)" do
    PluginSpecHelper.run("yum_repository", {
      "name" => "regen", "description" => "d", "baseurl" => "https://example.com", "gpgcheck" => "true", "reposdir" => TMP_DIR,
    })

    PluginSpecHelper.run("yum_repository", {
      "name" => "regen", "description" => "d", "baseurl" => "https://example.com", "priority" => "10", "reposdir" => TMP_DIR,
    })

    content = File.read(repo_path("regen"))
    content.should contain("priority = 10")
    content.should_not contain("gpgcheck")
  end

  it "writes to file: instead of name: when given" do
    PluginSpecHelper.run("yum_repository", {
      "name" => "myrepo", "description" => "d", "baseurl" => "https://example.com", "file" => "custom-file", "reposdir" => TMP_DIR,
    })

    File.exists?(repo_path("custom-file")).should be_true
    File.exists?(repo_path("myrepo")).should be_false
  end

  it "removes the file on state: absent" do
    PluginSpecHelper.run("yum_repository", {
      "name" => "toremove", "description" => "d", "baseurl" => "https://example.com", "reposdir" => TMP_DIR,
    })

    result = PluginSpecHelper.run("yum_repository", {"name" => "toremove", "state" => "absent", "reposdir" => TMP_DIR})

    result["changed"].as_bool.should be_true
    File.exists?(repo_path("toremove")).should be_false
  end

  it "reports changed: false for state: absent when the file doesn't exist" do
    result = PluginSpecHelper.run("yum_repository", {"name" => "never-existed", "state" => "absent", "reposdir" => TMP_DIR})

    result["changed"].as_bool.should be_false
  end

  it "fails with a clear message when description is missing" do
    result = PluginSpecHelper.run("yum_repository", {"name" => "x", "baseurl" => "https://example.com", "reposdir" => TMP_DIR})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("description")
  end

  it "fails with a clear message when none of baseurl/mirrorlist/metalink is given" do
    result = PluginSpecHelper.run("yum_repository", {"name" => "x", "description" => "d", "reposdir" => TMP_DIR})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("baseurl")
  end

  it "space-joins list parameters like includepkgs on one line" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "listtest",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "includepkgs" => "foo,bar",
      "reposdir"    => TMP_DIR,
    })

    File.read(repo_path("listtest")).should contain("includepkgs = foo bar")
  end

  # baseurl/gpgkey are real Ansible's own `type: list` params, joined with
  # a tab-indented continuation line rather than a space when there's more
  # than one - verified directly against real Python configparser output
  # (what real Ansible's own module uses to write the file), not assumed.
  # A single value renders as a plain `key = value` line either way, with
  # no continuation - only multiple values trigger it.
  it "tab-continuation-joins multi-value baseurl/gpgkey, matching real configparser output" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "multitest",
      "description" => "d",
      "baseurl"     => "https://a.example.com,https://b.example.com",
      "gpgkey"      => "https://example.com/key1,https://example.com/key2",
      "reposdir"    => TMP_DIR,
    })

    content = File.read(repo_path("multitest"))
    content.should contain("baseurl = https://a.example.com\n\thttps://b.example.com\n")
    content.should contain("gpgkey = https://example.com/key1\n\thttps://example.com/key2\n")
  end

  it "renders a single-value baseurl/gpgkey without a continuation line" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "singletest",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "gpgkey"      => "https://example.com/key1",
      "reposdir"    => TMP_DIR,
    })

    content = File.read(repo_path("singletest"))
    content.should contain("baseurl = https://example.com\n")
    content.should contain("gpgkey = https://example.com/key1\n")
  end

  it "writes newly-added tuning knobs as plain key = value lines" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "knobstest",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "cost"        => "500",
      "proxy"       => "http://proxy.example.com:8080",
      "sslverify"   => "false",
      "reposdir"    => TMP_DIR,
    })

    content = File.read(repo_path("knobstest"))
    content.should contain("cost = 500")
    content.should contain("proxy = http://proxy.example.com:8080")
    content.should contain("sslverify = 0")
  end

  # Real argument_spec aliases are resolved to the canonical key and the
  # alias spelling never lands in the file as its own key (real Ansible
  # pops aliases from the params dict before its write loop).
  it "resolves the excludepkgs alias to exclude" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "aliastest",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "excludepkgs" => "kernel*,docker-*",
      "reposdir"    => TMP_DIR,
    })

    content = File.read(repo_path("aliastest"))
    content.should contain("exclude = kernel* docker-*")
    content.should_not contain("excludepkgs")
  end

  it "resolves the TLS aliases (ca_cert/client_cert/client_key/validate_certs) to their canonical keys" do
    PluginSpecHelper.run("yum_repository", {
      "name"           => "tlstest",
      "description"    => "d",
      "baseurl"        => "https://example.com",
      "ca_cert"        => "/etc/pki/ca.crt",
      "client_cert"    => "/etc/pki/client.crt",
      "client_key"     => "/etc/pki/client.key",
      "validate_certs" => "false",
      "reposdir"       => TMP_DIR,
    })

    content = File.read(repo_path("tlstest"))
    content.should contain("sslcacert = /etc/pki/ca.crt")
    content.should contain("sslclientcert = /etc/pki/client.crt")
    content.should contain("sslclientkey = /etc/pki/client.key")
    content.should contain("sslverify = 0")
    content.should_not contain("ca_cert")
    content.should_not contain("client_cert")
    content.should_not contain("client_key")
    content.should_not contain("validate_certs")
  end

  # Two yum_repository tasks sharing one `file:` with different `name:`
  # sections is the normal main + source repo pattern (real role:
  # round900982 jaredledvina.sensu_go_ansible). Real Ansible's own module
  # merges via Python's configparser and converges to ok/ok on rerun;
  # overwriting the whole file with one section made both tasks report
  # changed: true on every rerun forever.
  it "merges a second section into a shared file instead of clobbering the first, converging on rerun" do
    params1 = {
      "name"        => "sensu_go",
      "description" => "Sensu Go main",
      "baseurl"     => "https://example.com/stable",
      "enabled"     => "true",
      "file"        => "shared",
      "reposdir"    => TMP_DIR,
    }
    params2 = {
      "name"        => "sensu_go-source",
      "description" => "Sensu Go source",
      "baseurl"     => "https://example.com/source",
      "enabled"     => "false",
      "file"        => "shared",
      "reposdir"    => TMP_DIR,
    }

    PluginSpecHelper.run("yum_repository", params1)
    PluginSpecHelper.run("yum_repository", params2)

    File.read(repo_path("shared")).should eq(
      "[sensu_go]\n" \
      "baseurl = https://example.com/stable\n" \
      "enabled = 1\n" \
      "name = Sensu Go main\n" \
      "\n" \
      "[sensu_go-source]\n" \
      "baseurl = https://example.com/source\n" \
      "enabled = 0\n" \
      "name = Sensu Go source\n" \
      "\n"
    )

    PluginSpecHelper.run("yum_repository", params1)["changed"].as_bool.should be_false
    PluginSpecHelper.run("yum_repository", params2)["changed"].as_bool.should be_false
  end

  # A .repo file can also be hand-edited or managed by a role with other
  # repos already in it - real Ansible's configparser-based rewrite
  # leaves those sections byte-for-byte alone.
  it "preserves an unrelated pre-existing section byte-for-byte when writing its own" do
    File.write(repo_path("preexisting"), "[unrelated]\nfoo = bar\ncomment = hand-edited\n\n[mine]\nbaseurl = https://old\nname = old\n\n")

    result = PluginSpecHelper.run("yum_repository", {
      "name"        => "mine",
      "description" => "Mine",
      "baseurl"     => "https://new",
      "file"        => "preexisting",
      "reposdir"    => TMP_DIR,
    })

    result["changed"].as_bool.should be_true
    content = File.read(repo_path("preexisting"))
    content.should contain("[unrelated]\nfoo = bar\ncomment = hand-edited\n\n")
    content.should contain("[mine]\nbaseurl = https://new\nname = Mine\n\n")
    content.should_not contain("https://old")

    PluginSpecHelper.run("yum_repository", {
      "name"        => "mine",
      "description" => "Mine",
      "baseurl"     => "https://new",
      "file"        => "preexisting",
      "reposdir"    => TMP_DIR,
    })["changed"].as_bool.should be_false
  end

  # A single task whose own section already matches exactly must stay
  # idempotent now that the comparison is full-file vs full-file - the
  # pre-fix comparison accidentally converged only because the file ever
  # held just the one section.
  it "still reports changed: false on rerun when its own section matches and the file holds other sections" do
    File.write(repo_path("mixed"), "[other]\nbaseurl = https://example.com/other\nname = Other\n\n[exact]\nbaseurl = https://example.com/exact\nname = Exact\n\n")

    result = PluginSpecHelper.run("yum_repository", {
      "name"        => "exact",
      "description" => "Exact",
      "baseurl"     => "https://example.com/exact",
      "file"        => "mixed",
      "reposdir"    => TMP_DIR,
    })

    result["changed"].as_bool.should be_false
    File.read(repo_path("mixed")).should eq(
      "[other]\n" \
      "baseurl = https://example.com/other\n" \
      "name = Other\n" \
      "\n" \
      "[exact]\n" \
      "baseurl = https://example.com/exact\n" \
      "name = Exact\n" \
      "\n"
    )
  end

  # A present alias beats the canonical name when both are given - real
  # ansible-core's _handle_aliases overwrite order (same convention stat.cr
  # verified against real Ansible).
  it "lets a present alias win over the canonical name when both are given" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "bothtest",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "exclude"     => "canonical-pkg",
      "excludepkgs" => "alias-pkg",
      "reposdir"    => TMP_DIR,
    })

    content = File.read(repo_path("bothtest"))
    content.should contain("exclude = alias-pkg")
    content.should_not contain("canonical-pkg")
  end
end
