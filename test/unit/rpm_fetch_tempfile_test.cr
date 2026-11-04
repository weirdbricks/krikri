require "../minitest_helper"
require "uri"
require "../../src/krikri/plugin_helpers/fetch_tempfile"
require "../../src/krikri/plugin_helpers/multiext_split"

# Ansible's fetch_file (ansible/module_utils/urls.py) stages a URL
# download as tempfile.NamedTemporaryFile(prefix=_split_multiext(basename,
# count=2)[0], suffix=...[1]) - the URL basename's stem around an
# 8-character random middle drawn from tempfile's _RandomNameSequence
# charset. dnf echoes that staged basename back in its own error text, so
# issue #818 surfaced ansible's "Public key for
# epel-release-latest-9.noarch<rand8>.rpm is not installed" while krikri's
# dnf/yum plugins staged the download under an opaque
# ".krikri-playbook-rpm-<rand8>.rpm" prefix of their own invention.
describe "PluginHelpers::FetchTempfile" do
  it "names the file stem + 8 lowercase/digit/underscore random chars + ext" do
    path = Krikri::PluginHelpers::FetchTempfile.create("epel-release-latest-9.noarch", ".rpm")
    begin
      basename = File.basename(path)
      basename.must_match(/^epel-release-latest-9\.noarch[a-z0-9_]{8}\.rpm$/)
    ensure
      File.delete(path) rescue nil
    end
  end

  it "keeps the name unique across creations" do
    first = Krikri::PluginHelpers::FetchTempfile.create("pkg.x86_64", ".rpm")
    second = Krikri::PluginHelpers::FetchTempfile.create("pkg.x86_64", ".rpm")
    begin
      File.basename(first).wont_equal(File.basename(second))
    ensure
      File.delete(first) rescue nil
      File.delete(second) rescue nil
    end
  end

  it "creates an empty 0600 file in the process temp dir" do
    path = Krikri::PluginHelpers::FetchTempfile.create("pkg", ".rpm")
    begin
      File.info(path).permissions.value.to_s(8).must_equal("600")
      File.size(path).must_equal(0)
      File.dirname(path).must_equal(Dir.tempdir)
    ensure
      File.delete(path) rescue nil
    end
  end

  it "derives the epel URL's stem and extension the way fetch_file does" do
    stem, ext = Krikri::PluginHelpers::MultiextSplit.split(
      File.basename(URI.parse("https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm").path))
    stem.must_equal("epel-release-latest-9.noarch")
    ext.must_equal(".rpm")
  end
end
