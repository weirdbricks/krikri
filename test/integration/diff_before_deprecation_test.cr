require "../minitest_helper"
require "file_utils"

# ansible's strategy dispatches the file diff (v2_on_file_diff) from its OK
# path BEFORE the runner-on-ok callback prints the result's warnings and
# deprecations, so a task that both diffs and deprecates renders diff,
# [DEPRECATION WARNING], then the status line (live-verified vs 2.21.6 with
# yum_repository's still-serialized `async` param). krikri printed the
# stderr banners first, which only shows up when both streams land in one
# place - the merged capture below, the same shape a `2>&1` run gives.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "diff and deprecation console order" do
  it "prints the file diff before the [DEPRECATION WARNING] it belongs to" do
    dir = PluginSpecHelper.tmp_path("diff-before-deprecation")
    repos = File.join(dir, "repos")
    FileUtils.mkdir_p(repos)
    playbook = File.join(dir, "play.yml")
    File.write(playbook, <<-PLAYBOOK)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: repo with a deprecated param
            ansible.builtin.yum_repository:
              name: kpg-fixture
              description: kpg fixture
              baseurl: https://example.com/repo
              reposdir: #{repos}
              async: true
      PLAYBOOK

    merged = File.join(dir, "merged.log")
    File.open(merged, "w") do |file|
      Process.run(BINARY, ["-i", "localhost,", playbook, "--diff"], output: file, error: file, chdir: dir)
    end
    text = File.read(merged)

    diff_pos = text.index!("--- before: ")
    warning_pos = text.index!("[DEPRECATION WARNING]: 'async' parameter is deprecated")
    changed_pos = text.index!("changed: [localhost]")
    (diff_pos < warning_pos).must_equal(true)
    (warning_pos < changed_pos).must_equal(true)
    text.must_include("+async = 1\n")
  end
end
