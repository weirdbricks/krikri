describe "divergence corpus" do
  it "replays 1597-mickengland-ldap-auth-client-debconf-dict" do
    expected, actual, report = divergence_transcripts(1597, "mickengland-ldap-auth-client-debconf-dict")
    assert_equal(expected, actual, report)
  end
end
