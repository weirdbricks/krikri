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
end
