describe "divergence corpus" do
  it "replays 1750-postgresql-privs-schema-not-allowed" do
    expected, actual, report = divergence_transcripts(1750, "postgresql-privs-schema-not-allowed")
    assert_equal(expected, actual, report)
  end
end
