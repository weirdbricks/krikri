describe "divergence corpus" do
  it "replays 1643-palvarez89-easyrsa3-synchronize-rsync-missing" do
    expected, actual, report = divergence_transcripts(1643, "palvarez89-easyrsa3-synchronize-rsync-missing")
    assert_equal(expected, actual, report)
  end
end
