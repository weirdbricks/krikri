require "../minitest_helper"
require "file_utils"

# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead
# (reposdir: wants the DIRECTORY, repo_path a file inside it).
private def repo_dir : String
  dir = PluginSpecHelper.tmp_path("repos")
  Dir.mkdir_p(dir)
  dir
end

private def repo_path(name : String) : String
  File.join(repo_dir, "#{name}.repo")
end

describe "yum_repository plugin" do
  it "writes a .repo file with keys sorted alphabetically and description as the name= field" do
    result = PluginSpecHelper.run("yum_repository", {
      "name"        => "epel",
      "description" => "EPEL YUM repo",
      "baseurl"     => "https://example.com/epel/$releasever/$basearch/",
      "gpgcheck"    => "true",
      "enabled"     => "true",
      "reposdir"    => repo_dir,
    })

    result["changed"].as_bool.must_equal(true)
    File.read(repo_path("epel")).must_equal(
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
      "reposdir"    => repo_dir,
    }
    PluginSpecHelper.run("yum_repository", params)

    result = PluginSpecHelper.run("yum_repository", params)

    result["changed"].as_bool.must_equal(false)
  end

  it "regenerates the section from scratch each run, dropping keys not passed this time (matches ansible-playbook, not a bug)" do
    PluginSpecHelper.run("yum_repository", {
      "name" => "regen", "description" => "d", "baseurl" => "https://example.com", "gpgcheck" => "true", "reposdir" => repo_dir,
    })

    PluginSpecHelper.run("yum_repository", {
      "name" => "regen", "description" => "d", "baseurl" => "https://example.com", "priority" => "10", "reposdir" => repo_dir,
    })

    content = File.read(repo_path("regen"))
    content.must_include("priority = 10")
    content.wont_include("gpgcheck")
  end

  it "writes to file: instead of name: when given" do
    PluginSpecHelper.run("yum_repository", {
      "name" => "myrepo", "description" => "d", "baseurl" => "https://example.com", "file" => "custom-file", "reposdir" => repo_dir,
    })

    File.exists?(repo_path("custom-file")).must_equal(true)
    File.exists?(repo_path("myrepo")).must_equal(false)
  end

  it "removes the file on state: absent" do
    PluginSpecHelper.run("yum_repository", {
      "name" => "toremove", "description" => "d", "baseurl" => "https://example.com", "reposdir" => repo_dir,
    })

    result = PluginSpecHelper.run("yum_repository", {"name" => "toremove", "state" => "absent", "reposdir" => repo_dir})

    result["changed"].as_bool.must_equal(true)
    File.exists?(repo_path("toremove")).must_equal(false)
  end

  it "reports changed: false for state: absent when the file doesn't exist" do
    result = PluginSpecHelper.run("yum_repository", {"name" => "never-existed", "state" => "absent", "reposdir" => repo_dir})

    result["changed"].as_bool.must_equal(false)
  end

  it "fails with a clear message when description is missing" do
    result = PluginSpecHelper.run("yum_repository", {"name" => "x", "baseurl" => "https://example.com", "reposdir" => repo_dir})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("description")
  end

  it "fails with a clear message when none of baseurl/mirrorlist/metalink is given" do
    result = PluginSpecHelper.run("yum_repository", {"name" => "x", "description" => "d", "reposdir" => repo_dir})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("baseurl")
  end

  it "space-joins list parameters like includepkgs on one line" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "listtest",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "includepkgs" => "foo,bar",
      "reposdir"    => repo_dir,
    })

    File.read(repo_path("listtest")).must_include("includepkgs = foo bar")
  end

  # baseurl/gpgkey are Ansible's own `type: list` params, joined with
  # a tab-indented continuation line rather than a space when there's more
  # than one - verified directly against real Python configparser output
  # (what Ansible's own module uses to write the file), not assumed.
  # A single value renders as a plain `key = value` line either way, with
  # no continuation - only multiple values trigger it.
  it "tab-continuation-joins multi-value baseurl/gpgkey, matching real configparser output" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "multitest",
      "description" => "d",
      "baseurl"     => "https://a.example.com,https://b.example.com",
      "gpgkey"      => "https://example.com/key1,https://example.com/key2",
      "reposdir"    => repo_dir,
    })

    content = File.read(repo_path("multitest"))
    content.must_include("baseurl = https://a.example.com\n\thttps://b.example.com\n")
    content.must_include("gpgkey = https://example.com/key1\n\thttps://example.com/key2\n")
  end

  it "renders a single-value baseurl/gpgkey without a continuation line" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "singletest",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "gpgkey"      => "https://example.com/key1",
      "reposdir"    => repo_dir,
    })

    content = File.read(repo_path("singletest"))
    content.must_include("baseurl = https://example.com\n")
    content.must_include("gpgkey = https://example.com/key1\n")
  end

  it "writes newly-added tuning knobs as plain key = value lines" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "knobstest",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "cost"        => "500",
      "proxy"       => "http://proxy.example.com:8080",
      "sslverify"   => "false",
      "reposdir"    => repo_dir,
    })

    content = File.read(repo_path("knobstest"))
    content.must_include("cost = 500")
    content.must_include("proxy = http://proxy.example.com:8080")
    content.must_include("sslverify = 0")
  end

  # Real argument_spec aliases are resolved to the canonical key and the
  # alias spelling never lands in the file as its own key (Ansible
  # pops aliases from the params dict before its write loop).
  it "resolves the excludepkgs alias to exclude" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "aliastest",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "excludepkgs" => "kernel*,docker-*",
      "reposdir"    => repo_dir,
    })

    content = File.read(repo_path("aliastest"))
    content.must_include("exclude = kernel* docker-*")
    content.wont_include("excludepkgs")
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
      "reposdir"       => repo_dir,
    })

    content = File.read(repo_path("tlstest"))
    content.must_include("sslcacert = /etc/pki/ca.crt")
    content.must_include("sslclientcert = /etc/pki/client.crt")
    content.must_include("sslclientkey = /etc/pki/client.key")
    content.must_include("sslverify = 0")
    content.wont_include("ca_cert")
    content.wont_include("client_cert")
    content.wont_include("client_key")
    content.wont_include("validate_certs")
  end

  # Two yum_repository tasks sharing one `file:` with different `name:`
  # sections is the normal main + source repo pattern (real role:
  # round900982 jaredledvina.sensu_go_ansible). Ansible's own module
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
      "reposdir"    => repo_dir,
    }
    params2 = {
      "name"        => "sensu_go-source",
      "description" => "Sensu Go source",
      "baseurl"     => "https://example.com/source",
      "enabled"     => "false",
      "file"        => "shared",
      "reposdir"    => repo_dir,
    }

    PluginSpecHelper.run("yum_repository", params1)
    PluginSpecHelper.run("yum_repository", params2)

    File.read(repo_path("shared")).must_equal(
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

    PluginSpecHelper.run("yum_repository", params1)["changed"].as_bool.must_equal(false)
    PluginSpecHelper.run("yum_repository", params2)["changed"].as_bool.must_equal(false)
  end

  # A .repo file can also be hand-edited or managed by a role with other
  # repos already in it - Ansible's configparser-based rewrite
  # leaves those sections byte-for-byte alone.
  it "preserves an unrelated pre-existing section byte-for-byte when writing its own" do
    File.write(repo_path("preexisting"), "[unrelated]\nfoo = bar\ncomment = hand-edited\n\n[mine]\nbaseurl = https://old\nname = old\n\n")

    result = PluginSpecHelper.run("yum_repository", {
      "name"        => "mine",
      "description" => "Mine",
      "baseurl"     => "https://new",
      "file"        => "preexisting",
      "reposdir"    => repo_dir,
    })

    result["changed"].as_bool.must_equal(true)
    content = File.read(repo_path("preexisting"))
    content.must_include("[unrelated]\nfoo = bar\ncomment = hand-edited\n\n")
    content.must_include("[mine]\nbaseurl = https://new\nname = Mine\n\n")
    content.wont_include("https://old")

    PluginSpecHelper.run("yum_repository", {
      "name"        => "mine",
      "description" => "Mine",
      "baseurl"     => "https://new",
      "file"        => "preexisting",
      "reposdir"    => repo_dir,
    })["changed"].as_bool.must_equal(false)
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
      "reposdir"    => repo_dir,
    })

    result["changed"].as_bool.must_equal(false)
    File.read(repo_path("mixed")).must_equal(
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
  # verified against Ansible).
  it "lets a present alias win over the canonical name when both are given" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "bothtest",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "exclude"     => "canonical-pkg",
      "excludepkgs" => "alias-pkg",
      "reposdir"    => repo_dir,
    })

    content = File.read(repo_path("bothtest"))
    content.must_include("exclude = alias-pkg")
    content.wont_include("canonical-pkg")
  end

  # yum_repository goes through BasePlugin#apply_owner_group_mode - the
  # SHARED owner/group helper - so it is the direct regression target for
  # the helper itself, distinct from copy/get_url's inline attribute code.
  # Found benchmarking kilip.chezmoi (round900811): a present-but-empty
  # owner:/group: was silently treated as "no ownership change requested"
  # instead of failing like Ansible's basic.py, which only skips the
  # chown/chgrp when the param is None and fails the empty-name lookup
  # with "chown failed: failed to look up user " (basic.py:789,
  # trailing space) / "chgrp failed: failed to look up group "
  # (basic.py:830). Verified live against ansible-core 2.19.11.
  it "fails with Ansible's exact message when owner: is an explicit empty string (shared helper)" do
    result = PluginSpecHelper.run("yum_repository", {
      "name"        => "empty-owner",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "owner"       => "",
      "reposdir"    => repo_dir,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("chown failed: failed to look up user ")
  end

  it "fails with Ansible's exact message when group: is an explicit empty string (shared helper)" do
    result = PluginSpecHelper.run("yum_repository", {
      "name"        => "empty-group",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "group"       => "",
      "reposdir"    => repo_dir,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("chgrp failed: failed to look up group ")
  end
end
