describe "divergence corpus" do
  it "replays 1771-thechip911-hardening-remove-tmp-from-fstab" do
    expected, actual, report = divergence_transcripts(1771, "thechip911-hardening-remove-tmp-from-fstab")
    assert_equal(expected, actual, report)
  end
end
