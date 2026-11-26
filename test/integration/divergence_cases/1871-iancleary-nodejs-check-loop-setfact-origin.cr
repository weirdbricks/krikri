describe "divergence corpus" do
  it "replays 1871-iancleary-nodejs-check-loop-setfact-origin" do
    expected, actual, report = divergence_transcripts(1871, "iancleary-nodejs-check-loop-setfact-origin")
    assert_equal(expected, actual, report)
  end
end
