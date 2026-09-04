require "../spec_helper"

# ec2_metadata_facts only makes sense on a real EC2 instance (IMDS lives
# at a link-local address that doesn't exist anywhere else) - this dev/CI
# box isn't one, so only the "can't reach IMDS" failure path is
# exercisable here. The full tree-walk/fact-flattening logic needs live
# verification on a real EC2 host - see KNOWN_MISSING.md.

describe "ec2_metadata_facts plugin" do
  it "fails cleanly when the metadata service is unreachable" do
    result = PluginSpecHelper.run("ec2_metadata_facts", {} of String => String)

    result["failed"].as_bool.should be_true
    # Off EC2 the token request times out or refuses ("Could not reach
    # the EC2 metadata service"), but on a cloud CI runner a real IMDS
    # answers the token request with a non-2xx ("Failed to retrieve
    # metadata token ... HTTP 400") - both are clean failures, and the
    # distinction is the environment's, not the plugin's.
    msg = result["msg"].as_s
    msg.should contain("metadata")
    msg.should match(/EC2 metadata service|HTTP \d+/)
  end

  it "fails cleanly for an out-of-range metadata_token_ttl_seconds" do
    result = PluginSpecHelper.run("ec2_metadata_facts", {"metadata_token_ttl_seconds" => "0"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("metadata_token_ttl_seconds")
  end
end
