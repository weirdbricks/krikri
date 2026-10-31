require "../minitest_helper"

# The Homebrew formula installs the release tarball's top-level entries by
# name, so a binary added to the tarball must also appear in the formula's
# install block or `brew install` silently skips it (krikri-lint did).
describe "Formula/krikri.rb install block" do
  private def install_body
    formula = File.read(File.join(__DIR__, "..", "..", "Formula", "krikri.rb"))
    body = formula.match(/def install\n(.*?)\n  end/m).try(&.[1])
    raise "no install block found in Formula/krikri.rb" unless body
    body
  end

  it "installs every top-level binary shipped in the release tarball" do
    ["krikri-playbook", "krikri", "krikri-lint"].each do |binary|
      install_body.must_match %r{bin\.install "#{binary}"}, "bin.install \"#{binary}\" missing from Formula/krikri.rb install block"
    end
  end

  it "does not install the internal differential_fuzz tool" do
    install_body.wont_match(/differential_fuzz/)
  end
end
