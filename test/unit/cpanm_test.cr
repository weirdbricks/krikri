require "../minitest_helper"
require "../../src/krikri/plugin_helpers/cpanm"

describe "Cpanm helper" do
  it "builds the install argv in the module's flag order" do
    Krikri::PluginHelpers::Cpanm.install_argv("/usr/bin/cpanm", "Mail::DMARC::PurePerl", true, nil, nil, false, false)
      .must_equal(["/usr/bin/cpanm", "--notest", "Mail::DMARC::PurePerl"])
    Krikri::PluginHelpers::Cpanm.install_argv("cpanm", "X", false, "/ll", "http://m", true, true)
      .must_equal(["cpanm", "--local-lib", "/ll", "--mirror", "http://m", "--mirror-only", "--installdeps", "X"])
  end

  it "probes with perl use and never treats a tarball as installed" do
    Krikri::PluginHelpers::Cpanm.probe_command("Foo::Bar", nil, nil)
      .must_equal("perl -le 'use Foo::Bar; print \"OK\";'")
    Krikri::PluginHelpers::Cpanm.probe_command("x.tar.gz", nil, nil).must_be_nil
  end

  it "reports changed only on rc 0 without 'is up to date'" do
    Krikri::PluginHelpers::Cpanm.changed?(0, "installed", "").must_equal(true)
    Krikri::PluginHelpers::Cpanm.changed?(0, "Foo is up to date", "").must_equal(false)
    Krikri::PluginHelpers::Cpanm.changed?(1, "", "").must_equal(false)
  end

  it "rejects name with from_path only in the default mode=new" do
    Krikri::PluginHelpers::Cpanm.setup_error("nsreaz", "/tmp/x.txt", "new", nil)
      .must_equal("Parameters 'name' and 'from_path' are mutually exclusive when 'mode=new'")
    Krikri::PluginHelpers::Cpanm.setup_error("nsreaz", nil, "new", nil).must_be_nil
    Krikri::PluginHelpers::Cpanm.setup_error(nil, "/tmp/x.txt", "new", nil).must_be_nil
    # compatibility mode itself raises on name_check instead, and lets
    # name + from_path through (it only ever uses one of them).
    Krikri::PluginHelpers::Cpanm.setup_error("nsreaz", "/tmp/x.txt", "compatibility", nil).must_be_nil
    Krikri::PluginHelpers::Cpanm.setup_error("nsreaz", nil, "compatibility", "Foo::Bar")
      .must_equal("Parameter name_check can only be used with mode=new")
  end
end

describe "Cpanm plugin" do
  it "fails name with from_path the way ModuleHelper's own raise does" do
    result = PluginSpecHelper.run("cpanm", {
      "name"                    => "nsreaz",
      "from_path"               => "/tmp/kpg-work/readonly/dest.txt",
      "install_recommendations" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Parameters 'name' and 'from_path' are mutually exclusive when 'mode=new'")
    # ModuleHelper's output_params (name, version) ride along under both
    # `output` and `vars` and are repeated at the top level; the raise
    # happens before cpanm is ever invoked, so there is no cmd/rc.
    result["output"]["name"].as_s.must_equal("nsreaz")
    result["vars"]["name"].as_s.must_equal("nsreaz")
    result["name"].as_s.must_equal("nsreaz")
    result["version"].raw.must_be_nil
    result.as_h.has_key?("cmd").must_equal(false)
  end

  it "adds the empty diff dicts under --diff" do
    result = PluginSpecHelper.run("cpanm", {
      "name"          => "nsreaz",
      "from_path"     => "/tmp/kpg-work/readonly/dest.txt",
      "_ansible_diff" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["diff"].as_h.empty?.must_equal(true)
    result["output"]["diff"].as_h.empty?.must_equal(true)
    result["vars"].as_h.has_key?("diff").must_equal(false)
  end

  it "skips in check mode like a module without supports_check_mode" do
    result = PluginSpecHelper.run("cpanm", {
      "name"                => "nsreaz",
      "from_path"           => "/tmp/kpg-work/readonly/dest.txt",
      "_ansible_check_mode" => "true",
    })

    result["skipped"].as_bool.must_equal(true)
    result["failed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("remote module (community.general.cpanm) does not support check mode")
  end

  it "still fails a missing name/from_path in check mode first" do
    result = PluginSpecHelper.run("cpanm", {
      "_ansible_check_mode" => "true",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("one of the following is required: name, from_path")
  end
end
