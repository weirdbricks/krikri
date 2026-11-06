require "../minitest_helper"
require "../../src/krikri/plugin_helpers/url_mask"

# Every expectation here is a real ansible-core 2.21.6 run of
# ansible.module_utils.urls.mask_url() with the same input.
describe Krikri::PluginHelpers::UrlMask do
  it "masks a username and password in the userinfo" do
    Krikri::PluginHelpers::UrlMask.mask("http://user:pass@example.com/path?q=1#frag")
      .must_equal("http://****:****@example.com/path?q=1#frag")
  end

  it "masks a username with no password" do
    Krikri::PluginHelpers::UrlMask.mask("http://user@example.com/path")
      .must_equal("http://****@example.com/path")
  end

  it "returns a URL without userinfo unchanged" do
    Krikri::PluginHelpers::UrlMask.mask("http://example.com/path")
      .must_equal("http://example.com/path")
    Krikri::PluginHelpers::UrlMask.mask("ftp://example.com/file.iso")
      .must_equal("ftp://example.com/file.iso")
    Krikri::PluginHelpers::UrlMask.mask("").must_equal("")
  end

  it "splits the userinfo at the first colon, keeping colons in the password" do
    Krikri::PluginHelpers::UrlMask.mask("https://user:pa:ss@example.com:8443/x")
      .must_equal("https://****:****@example.com:8443/x")
  end

  it "matches the raw, still percent-encoded userinfo" do
    Krikri::PluginHelpers::UrlMask.mask("http://u%40x:p@example.com/y")
      .must_equal("http://****:****@example.com/y")
  end

  it "leaves an empty password alone (the Python original's truthiness branch)" do
    Krikri::PluginHelpers::UrlMask.mask("http://user:@example.com/y")
      .must_equal("http://user:@example.com/y")
  end

  it "masks a password with an empty username" do
    Krikri::PluginHelpers::UrlMask.mask("http://:pass@h/x")
      .must_equal("http://****:****@h/x")
  end

  it "only touches the netloc, not an @ in the query" do
    Krikri::PluginHelpers::UrlMask.mask("http://a:b@h/p?user:x@h")
      .must_equal("http://****:****@h/p?user:x@h")
    Krikri::PluginHelpers::UrlMask.mask("http://U:P@H/P?a=@")
      .must_equal("http://****:****@H/P?a=@")
  end

  it "masks a userinfo with no path" do
    Krikri::PluginHelpers::UrlMask.mask("http://u:p@h").must_equal("http://****:****@h")
  end

  it "masks a scheme-relative URL" do
    Krikri::PluginHelpers::UrlMask.mask("//u:p@h/x").must_equal("//****:****@h/x")
  end
end
