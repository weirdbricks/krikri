describe "divergence corpus" do
  it "replays 1830-unarchive-creates-unsearchable-dir" do
    # The recorded transcript only exists for an unprivileged user: root
    # ignores the search bit the role's own `mode: u=rw,g=r,o=r` strips from
    # the extracted directories, so the creates: probe answers "exists"
    # there and the task skips on both engines.
    skip("needs an unprivileged run: root ignores the search bit") if PluginSpecHelper.running_as_root?
    expected, actual, report = divergence_transcripts(1830, "unarchive-creates-unsearchable-dir")
    assert_equal(expected, actual, report)
  end
end
