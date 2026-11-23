describe "divergence corpus" do
  it "replays 1731-lotusnoir-apps-snoopy-vars-lookup-fact-deprecation" do
    expected, actual, report = divergence_transcripts(1731, "lotusnoir-apps-snoopy-vars-lookup-fact-deprecation")
    assert_equal(expected, actual, report)
  end
end
