describe "divergence corpus" do
  it "replays 1818-unarchive-exploded-file-permission-denied" do
    # The recorded failure only exists for an unprivileged user: root's
    # lstat/chmod ignore the search bit the attribute pass itself removes,
    # so both engines succeed there.
    skip("needs an unprivileged run: root ignores the search bit") if PluginSpecHelper.running_as_root?
    expected, actual, report = divergence_transcripts(1818, "unarchive-exploded-file-permission-denied")
    assert_equal(expected, actual, report)
  end
end
