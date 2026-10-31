require "../minitest_helper"
require "json"
require "../../src/krikri/aws_secret_lookup"
require "../../src/krikri/variable_substitutor/expression_evaluator"
require "../../src/krikri/krikri_jinja_lookups"
require "../../src/krikri/krikri_jinja_filters"

# Issue #689: lookup('amazon.aws.aws_secret', ...) degraded to the
# "undefined" sentinel (query() to []) for an INSTALLED collection - the
# dispatch chain had no arm for collection lookups and the PythonLookupRunner
# deliberately does not reach inside installed collections - and never
# failed when the secret could not be fetched. The helper runs through the
# transport seam (no network): every canned response is what a real
# Secrets Manager JSON-API call returns, and the dispatch-level assertions
# pin the shapes live-verified against ansible-core 2.19.11 +
# amazon.aws 10.1.1 (through botocore's endpoint override against a local
# fake Secrets Manager).
describe "amazon.aws.aws_secret lookup (aws_secret_lookup_test.cr)" do
  serial! # mutates process-global state (ENV / the transport seam)

  before_each do
    # The lookup resolves region/credentials from the environment - pin
    # them so the specs neither depend on the runner's real AWS env nor
    # leak into it (every test passes its own access_key/secret_key
    # options anyway; the env pins exist for the resolution-order paths).
    @old = {
      "AWS_ACCESS_KEY_ID"               => ENV["AWS_ACCESS_KEY_ID"]?,
      "AWS_SECRET_ACCESS_KEY"           => ENV["AWS_SECRET_ACCESS_KEY"]?,
      "AWS_REGION"                      => ENV["AWS_REGION"]?,
      "AWS_DEFAULT_REGION"              => ENV["AWS_DEFAULT_REGION"]?,
      "AWS_ENDPOINT_URL"                => ENV["AWS_ENDPOINT_URL"]?,
      "AWS_ENDPOINT_URL_SECRETSMANAGER" => ENV["AWS_ENDPOINT_URL_SECRETSMANAGER"]?,
    }
    ENV.delete("AWS_ENDPOINT_URL")
    ENV.delete("AWS_ENDPOINT_URL_SECRETSMANAGER")
    ENV["AWS_ACCESS_KEY_ID"] = "test-access"
    ENV["AWS_SECRET_ACCESS_KEY"] = "test-secret"
    ENV["AWS_REGION"] = "us-east-1"
    ENV.delete("AWS_DEFAULT_REGION")
  end

  after_each do
    @old.try do |saved|
      saved.each do |key, value|
        if value
          ENV[key] = value
        else
          ENV.delete(key)
        end
      end
    end
    Krikri::AwsSecretLookup.transport = nil
  end

  private def canned(status : Int32, body : String, &)
    requests = [] of Tuple(String, String)
    Krikri::AwsSecretLookup.transport = ->(target : String, request_body : String) do
      requests << {target, request_body}
      {status, body}
    end
    result = yield requests
    Krikri::AwsSecretLookup.transport = nil
    result
  end

  private def found_response(secret : String) : String
    {"Name" => "krikri-test-synthetic", "SecretString" => secret,
     "VersionId" => "v-1", "CreatedDate" => 1700000000.0}.to_json
  end

  private def missing_response : String
    {"__type"  => "ResourceNotFoundException",
     "message" => "Secrets Manager can't find the specified secret."}.to_json
  end

  it "returns the secret string through the hand-rolled lookup() dispatch" do
    canned(200, found_response("s3cr3t")) do |_requests|
      v = Hash(String, JSON::Any).new
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
      evaluator.evaluate("lookup('amazon.aws.aws_secret', 'krikri-test-synthetic', " \
                         "access_key='k', secret_key='s')").must_equal("s3cr3t")
    end
  end

  it "returns the secret string through the krikri-jinja query() dispatch" do
    canned(200, found_response("s3cr3t")) do |_requests|
      KrikriJinja.render("{{ query('amazon.aws.aws_secret', 'krikri-test-synthetic', " \
                         "access_key='k', secret_key='s') }}", {} of String => JSON::Any)
        .must_equal("['s3cr3t']")
    end
  end

  it "sends GetSecretValue with the term as SecretId and passes version options" do
    canned(200, found_response("s3cr3t")) do |requests|
      options = {"version_stage" => "AWSCURRENT"} of String => String
      Krikri::AwsSecretLookup.run(["krikri-test-synthetic"], options)
      target, body = requests.first
      target.must_equal("secretsmanager.GetSecretValue")
      JSON.parse(body)["SecretId"].as_s.must_equal("krikri-test-synthetic")
      JSON.parse(body)["VersionStage"].as_s.must_equal("AWSCURRENT")
    end
  end

  it "fails the task with the plugin's own ResourceNotFound message" do
    # ansible: "The lookup plugin 'amazon.aws.aws_secret' failed: Failed to
    # find secret kk-nonexistent-secret-xyz (ResourceNotFound)", exit 2 -
    # the old dispatch never failed at all (it returned "undefined").
    canned(400, missing_response) do |_requests|
      v = Hash(String, JSON::Any).new
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
      error = assert_raises(Krikri::PythonLookupRunner::LookupError) do
        evaluator.evaluate("lookup('amazon.aws.aws_secret', 'no-such-secret', " \
                           "access_key='k', secret_key='s')")
      end
      error.message.must_equal(
        "The lookup plugin 'amazon.aws.aws_secret' failed: Failed to find secret no-such-secret (ResourceNotFound)")
    end
  end

  it "keeps on_missing=skip silent and drops the term from the result" do
    canned(400, missing_response) do |_requests|
      v = Hash(String, JSON::Any).new
      evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)
      evaluator.evaluate("query('amazon.aws.aws_secret', 'no-such-secret', " \
                         "access_key='k', secret_key='s', on_missing='skip')").must_equal("[]")
    end
  end

  it "walks the nested dotted-key syntax into the secret's JSON body" do
    canned(200, found_response(%({"A": "x", "B": "y"}))) do |_requests|
      result = Krikri::AwsSecretLookup.run(
        ["krikri-test-synthetic.A"],
        {"nested" => "true", "access_key" => "k", "secret_key" => "s"} of String => String)
      result.size.must_equal(1)
      result[0].as_s.must_equal("x")
    end
  end

  it "joins multiple terms into one string with join=true" do
    canned(200, found_response("s3cr3t")) do |_requests|
      result = Krikri::AwsSecretLookup.run(
        ["krikri-test-synthetic", "krikri-test-synthetic"],
        {"join" => "true", "access_key" => "k", "secret_key" => "s"} of String => String)
      result.size.must_equal(1)
      result[0].as_s.must_equal("s3cr3ts3cr3t")
    end
  end

  it "lists the hierarchy's secrets as one name->value dict with bypath=true" do
    requests = [] of Tuple(String, String)
    Krikri::AwsSecretLookup.transport = ->(target : String, request_body : String) do
      requests << {target, request_body}
      target == "secretsmanager.ListSecrets" ? {200, {"SecretList" => [{"Name" => "krikri-test-synthetic"}]}.to_json} : {200, found_response("s3cr3t")}
    end
    result = Krikri::AwsSecretLookup.run(
      ["krikri-test-synthetic"],
      {"bypath" => "true", "access_key" => "k", "secret_key" => "s"} of String => String)
    result.size.must_equal(1)
    result[0].as_h["krikri-test-synthetic"].as_s.must_equal("s3cr3t")
    targets = requests.map { |entry| entry[0] }
    targets.includes?("secretsmanager.ListSecrets").must_equal(true)
    targets.includes?("secretsmanager.GetSecretValue").must_equal(true)
  end

  it "warns and drops the term when on_missing=warn" do
    canned(400, missing_response) do |_requests|
      warnings = [] of String
      result = Krikri::AwsSecretLookup.run(
        ["no-such-secret"],
        {"on_missing" => "warn", "access_key" => "k", "secret_key" => "s"} of String => String,
        warning_sink: ->(warning : String) { warnings << warning })
      result.must_equal([] of JSON::Any)
      warnings.must_equal(["Skipping, did not find secret no-such-secret"])
    end
  end

  it "reports the marked-for-deletion branch through its own message" do
    canned(400, {"__type"  => "InvalidRequestException",
                 "message" => "Secret krikri-test-synthetic marked for deletion."}.to_json) do |_requests|
      error = assert_raises(Krikri::AwsSecretLookup::Error) do
        Krikri::AwsSecretLookup.run(["krikri-test-synthetic"],
          {"access_key" => "k", "secret_key" => "s"} of String => String)
      end
      error.message.must_equal("Failed to find secret krikri-test-synthetic (marked for deletion)")
    end
  end

  it "requires a region the way the collection plugin's base class does" do
    ENV.delete("AWS_REGION")
    ENV.delete("AWS_DEFAULT_REGION")
    error = assert_raises(Krikri::AwsSecretLookup::Error) do
      Krikri::AwsSecretLookup.run(["krikri-test-synthetic"],
        {"access_key" => "k", "secret_key" => "s"} of String => String)
    end
    error.message.must_equal("The amazon.aws.secretsmanager_secret plugin requires a region " \
                             "and none was found in configuration, environment variables or module parameters")
  ensure
    ENV["AWS_REGION"] = "us-east-1"
  end

  it "reports the botocore no-credentials text when credentials are absent" do
    ENV.delete("AWS_ACCESS_KEY_ID")
    ENV.delete("AWS_SECRET_ACCESS_KEY")
    error = assert_raises(Krikri::AwsSecretLookup::Error) do
      Krikri::AwsSecretLookup.run(["krikri-test-synthetic"], {} of String => String)
    end
    error.message.must_equal("Failed to retrieve secret: Unable to locate credentials")
  ensure
    ENV["AWS_ACCESS_KEY_ID"] = "test-access"
    ENV["AWS_SECRET_ACCESS_KEY"] = "test-secret"
  end
end
