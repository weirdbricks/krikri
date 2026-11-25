describe "divergence corpus" do
  it "replays 1794-shomatan-laravel-ensure-cronie-noanacron-is-installed" do
    expected, actual, report = divergence_transcripts(1794, "shomatan-laravel-ensure-cronie-noanacron-is-installed")
    assert_equal(expected, actual, report)
  end
end
