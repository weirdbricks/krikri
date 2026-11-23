require "../minitest_helper"

private PROJECT_ROOT     = File.expand_path("../..", __DIR__)
private RELEASE_WORKFLOW = File.join(PROJECT_ROOT, ".github", "workflows", "release.yml")

# release.yml stages bin/ wholesale (`cp -al bin/*`), so anything `./build.sh`
# leaves there rides into every release tarball - including tools that have no
# runtime role for users. These specs pin which binaries may ship: issue #1698
# found krikri-capture-case (a maintainer-only corpus capture tool that needs a
# pinned real ansible-core) in all four per-arch tarballs, and the multi-arch
# bundles are re-tarred from those, so the per-arch staging step is the one
# place to get it right.
describe "release workflow tarball staging" do
  it "drops the maintainer-only krikri-capture-case from every staged tarball" do
    lines = File.read_lines(RELEASE_WORKFLOW)

    staging = lines.each_with_index.select { |line, _| line.includes?("cp -al bin/*") }.map { |_, index| index }
    staging.size.must_equal(2, "expected one `cp -al bin/*` per job (Linux and macOS)")

    staging.each do |index|
      staged = lines[(index + 1)..]
      tar_index = staged.index { |line| line.includes?("tar -C dist") }
      flunk("no `tar -C dist` after the staging step at line #{index + 1}") if tar_index.nil?

      before_tar = staged[0, tar_index]
      before_tar.any? { |line| line.includes?("rm ") && line.includes?("krikri-capture-case") }
        .must_equal(true,
          "the staging step at line #{index + 1} tars bin/ before removing krikri-capture-case " \
          "(issue #1698 - the tool has no runtime role for users)")
    end
  end

  it "keeps krikri-ssm-pipe in the tarball" do
    # SsmRsyncRsh uploads this one to targets, so it is a genuine runtime
    # artifact despite also being built by ./build.sh rather than linked.
    File.read_lines(RELEASE_WORKFLOW)
      .any? { |line| line.includes?("rm ") && line.includes?("krikri-ssm-pipe") }
      .must_equal(false, "release.yml removes krikri-ssm-pipe, which synchronize: over aws_ssm needs on targets")
  end
end
