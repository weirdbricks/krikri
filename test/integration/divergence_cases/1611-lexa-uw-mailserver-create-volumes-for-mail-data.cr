describe "divergence corpus" do
  it "replays 1611-lexa-uw-mailserver-create-volumes-for-mail-data" do
    expected, actual, report = divergence_transcripts(1611, "lexa-uw-mailserver-create-volumes-for-mail-data")
    assert_equal(expected, actual, report)
  end
end
