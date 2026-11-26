describe "divergence corpus" do
  it "replays 1861-isu-ansible-realmd-imported-macro-vars-origin" do
    expected, actual, report = divergence_transcripts(1861, "isu-ansible-realmd-imported-macro-vars-origin")
    assert_equal(expected, actual, report)
  end
end
