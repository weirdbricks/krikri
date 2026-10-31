require "json"
require "base64"
require "http/client"
require "uri"
require "awscr-signer"

module Krikri
  # Native amazon.aws.aws_secret lookup (Secrets Manager GetSecretValue) -
  # the controller-side counterpart of the signed-Query-API amazon.aws
  # module cluster in PluginHelpers (those run as separate plugin binaries,
  # so the main executable cannot require them; this helper carries the
  # same credential/region contract itself: the AWS_* environment
  # variables and the lookup's own region/access_key/secret_key/
  # session_token/endpoint_url options, without the boto profile machinery).
  #
  # Semantics mirror the collection plugin's own run()/get_secret_value
  # (amazon.aws 10.x, GPL, read for parity): one GetSecretValue per term,
  # only truthy values appended, the on_missing/on_denied/on_deleted
  # policies, `bypath` listing via ListSecrets, the `nested` dotted-key
  # walk and `join` concatenation. Errors raise Error with the plugin's
  # own message text (no wrapper prefix) - the dispatchers add the generic
  # "The lookup plugin '<name>' failed: " shape around it.
  module AwsSecretLookup
    class Error < Exception
    end

    record Credentials, access_key : String, secret_key : String, session_token : String?

    # The JSON API's error shape: {"__type": "...#ResourceNotFoundException",
    # "message": "..."} - botocore strips the type prefix; some endpoints
    # spell the fields "code"/"Message" instead.
    class AwsApiError < Exception
      getter code : String
      getter api_message : String
      getter status : Int32

      def initialize(@status : Int32, body : JSON::Any)
        @code = body["__type"]?.try(&.as_s?).try { |type_text| type_text.split('#').last } ||
                body["code"]?.try(&.as_s?) || ""
        @api_message = body["message"]?.try(&.as_s?) || body["Message"]?.try(&.as_s?) || ""
        super("AWS #{code}: #{api_message}")
      end
    end

    # Test seam: ("secretsmanager.GetSecretValue", request JSON body) ->
    # {HTTP status, response body}. Specs feed canned responses and assert
    # on the exact request bodies instead of a real signed round trip.
    @@transport : Proc(String, String, Tuple(Int32, String))? = nil

    def self.transport=(proc : Proc(String, String, Tuple(Int32, String))?) : Nil
      @@transport = proc
    end

    def self.transport? : Proc(String, String, Tuple(Int32, String))?
      @@transport
    end

    # Runs the lookup over *terms* (secret names, possibly `nested` dotted
    # paths), returning the plugin's result list. Warnings (on_missing/
    # on_denied/on_deleted = "warn") travel through the optional block.
    def self.run(terms : Array(String), options : Hash(String, String),
                 warning_sink : Proc(String, Nil)? = nil) : Array(JSON::Any)
      on_missing = policy_option(options, "on_missing")
      on_denied = policy_option(options, "on_denied")
      on_deleted = policy_option(options, "on_deleted")
      bypath = flag?(options, "bypath")
      nested = flag?(options, "nested")
      join = flag?(options, "join")

      if bypath
        secrets = {} of String => JSON::Any
        terms.each do |term|
          list_secrets(term, options).each do |name|
            secrets[name] = get_secret_value(name, options, on_missing, on_denied, on_deleted,
              warning_sink: warning_sink)
          end
        end
        return [JSON::Any.new(secrets)]
      end

      values = [] of JSON::Any
      terms.each do |term|
        value = get_secret_value(term, options, on_missing, on_denied, on_deleted, nested,
          warning_sink: warning_sink)
        # The plugin appends only truthy values - a skip/warn miss or an
        # empty-string secret stays out of the result list entirely.
        next if value.raw.nil?
        next if (raw = value.raw).is_a?(String) && raw.empty?
        values << value
      end
      return [JSON::Any.new(values.map { |value| value.as_s? || value.to_s }.join(""))] if join
      values
    end

    private def self.policy_option(options : Hash(String, String), key : String) : String
      value = options[key]?
      return "error" if value.nil? || value.empty?
      return value.downcase if value.downcase.in?("error", "warn", "skip")
      raise Error.new(%("#{key}" must be a string and one of "error", "warn" or "skip", not #{value}))
    end

    private def self.flag?(options : Hash(String, String), key : String) : Bool
      raw = options[key]?
      return false if raw.nil? || raw.empty?
      raw.downcase == "true"
    end

    private def self.region(options : Hash(String, String)) : String
      region = options["region"]? || options["aws_region"]? ||
               ENV["AWS_REGION"]? || ENV["AWS_DEFAULT_REGION"]?
      return region unless region.nil? || region.empty?
      # AWSLookupBase's own pre-flight refusal, before any API call is made.
      raise Error.new("The amazon.aws.secretsmanager_secret plugin requires a region " \
                      "and none was found in configuration, environment variables or module parameters")
    end

    private def self.endpoint(options : Hash(String, String), region : String) : URI
      url = options["endpoint_url"]? || options["aws_endpoint_url"]? ||
            ENV["AWS_ENDPOINT_URL_SECRETSMANAGER"]? || ENV["AWS_ENDPOINT_URL"]?
      URI.parse(url && !url.empty? ? url : "https://secretsmanager.#{region}.amazonaws.com")
    end

    private def self.json_post(target : String, body : String, options : Hash(String, String)) : JSON::Any
      region = region(options)
      credentials = credentials(options)

      if transport = @@transport
        status, response_body = transport.call(target, body)
        return parse_json_response(status, response_body)
      end

      endpoint = self.endpoint(options, region)
      host = endpoint.host || "secretsmanager.#{region}.amazonaws.com"
      host = "#{host}:#{endpoint.port}" if endpoint.port
      request = HTTP::Request.new("POST", endpoint.request_target, HTTP::Headers{
        "Host"         => host,
        "Content-Type" => "application/x-amz-json-1.1",
        "X-Amz-Target" => target,
      }, body)

      signer = Awscr::Signer::Signers::V4.new("secretsmanager", region,
        credentials.access_key, credentials.secret_key, credentials.session_token)
      signer.sign(request)

      response = HTTP::Client.new(endpoint).post(endpoint.request_target,
        headers: request.headers, body: body)
      parse_json_response(response.status_code, response.body)
    end

    private def self.parse_json_response(status : Int32, body : String) : JSON::Any
      parsed = JSON.parse(body.empty? ? "{}" : body)
      return parsed if status.in?(200..299)
      raise AwsApiError.new(status, parsed)
    end

    # First candidate that is present and non-empty - the option spellings
    # precede the environment fallbacks (real's precedence: explicit
    # parameters beat the boto environment chain).
    private def self.first_present(*candidates : String?) : String?
      candidates.each do |candidate|
        return candidate if candidate && !candidate.empty?
      end
      nil
    end

    private def self.credentials(options : Hash(String, String)) : Credentials
      access_key = first_present(options["access_key"]?, options["aws_access_key"]?,
        options["aws_access_key_id"]?, ENV["AWS_ACCESS_KEY_ID"]?, ENV["AWS_ACCESS_KEY"]?)
      secret_key = first_present(options["secret_key"]?, options["aws_secret_key"]?,
        options["aws_secret_access_key"]?, ENV["AWS_SECRET_ACCESS_KEY"]?, ENV["AWS_SECRET_KEY"]?)
      session_token = first_present(options["session_token"]?, options["aws_session_token"]?,
        ENV["AWS_SESSION_TOKEN"]?, ENV["AWS_SECURITY_TOKEN"]?)
      return Credentials.new(access_key, secret_key, session_token) if access_key && secret_key
      # botocore's NoCredentialsError text, caught by the plugin's generic
      # ClientError/BotoCoreError handler like every other call failure.
      raise Error.new("Failed to retrieve secret: Unable to locate credentials")
    end

    private def self.list_secrets(term : String, options : Hash(String, String)) : Array(String)
      names = [] of String
      next_token = nil
      loop do
        body = {"Filters" => [{"Key" => "name", "Values" => [term]}]}.to_json
        body = {"Filters" => [{"Key" => "name", "Values" => [term]}], "NextToken" => next_token}.to_json if next_token
        response = json_post("secretsmanager.ListSecrets", body, options)
        response["SecretList"]?.try(&.as_a?).try do |secrets|
          secrets.each do |secret|
            name = secret["Name"]?.try(&.as_s?)
            names << name if name && !names.includes?(name)
          end
        end
        next_token = response["NextToken"]?.try(&.as_s?)
        break if next_token.nil? || next_token.empty?
      end
      names
    rescue ex : AwsApiError
      raise Error.new("Failed to retrieve secret: #{client_error_text(ex, "ListSecrets")}")
    end

    private def self.get_secret_value(term : String, options : Hash(String, String),
                                      on_missing : String, on_denied : String, on_deleted : String,
                                      nested : Bool = false,
                                      warning_sink : Proc(String, Nil)? = nil) : JSON::Any
      secret_id = nested ? nested_secret_id(term) : term

      begin
        response = json_post("secretsmanager.GetSecretValue", get_value_request(secret_id, options), options)
        return secret_binary_value(response["SecretBinary"].as_s) if response["SecretBinary"]?.try(&.as_s?)
        secret_string = response["SecretString"]?.try(&.as_s?) || ""
        return JSON::Any.new(secret_string) unless nested
        nested_value(secret_string, term, on_missing, warning_sink)
      rescue ex : AwsApiError
        api_error_value(ex, term, on_missing, on_denied, on_deleted, warning_sink)
      end
    end

    private def self.nested_secret_id(term : String) : String
      if term.split('.').size < 2
        raise Error.new("Nested query must use the following syntax: `aws_secret_name.<key_name>.<key_name>")
      end
      term.split('.')[0]
    end

    private def self.get_value_request(secret_id : String, options : Hash(String, String)) : String
      request = {"SecretId" => secret_id}
      if (version_stage = options["version_stage"]?) && !version_stage.empty?
        request = request.merge({"VersionStage" => version_stage})
      end
      if (version_id = options["version_id"]?) && !version_id.empty?
        request = request.merge({"VersionId" => version_id})
      end
      request.to_json
    end

    private def self.secret_binary_value(binary : String) : JSON::Any
      begin
        JSON::Any.new(Base64.decode_string(binary))
      rescue Base64::Error
        JSON::Any.new(binary)
      end
    end

    # The plugin's own three specific handlers (deletion is matched by its
    # message text, then the two error codes) around the generic
    # ClientError fallthrough.
    private def self.api_error_value(ex : AwsApiError, term : String, on_missing : String,
                                     on_denied : String, on_deleted : String,
                                     warning_sink : Proc(String, Nil)?) : JSON::Any
      return deletion_error_value(term, on_deleted, warning_sink) if ex.api_message.includes?("marked for deletion")
      return missing_error_value(term, on_missing, warning_sink) if ex.code == "ResourceNotFoundException"
      return denied_error_value(term, on_denied, warning_sink) if ex.code == "AccessDeniedException"
      raise Error.new("Failed to retrieve secret: #{client_error_text(ex)}")
    end

    private def self.deletion_error_value(term : String, on_deleted : String,
                                          warning_sink : Proc(String, Nil)?) : JSON::Any
      case on_deleted
      when "error" then raise Error.new("Failed to find secret #{term} (marked for deletion)")
      when "warn"  then warning_sink.try(&.call("Skipping, did not find secret (marked for deletion) #{term}"))
      end
      JSON::Any.new(nil)
    end

    private def self.missing_error_value(term : String, on_missing : String,
                                         warning_sink : Proc(String, Nil)?) : JSON::Any
      case on_missing
      when "error" then raise Error.new("Failed to find secret #{term} (ResourceNotFound)")
      when "warn"  then warning_sink.try(&.call("Skipping, did not find secret #{term}"))
      end
      JSON::Any.new(nil)
    end

    private def self.denied_error_value(term : String, on_denied : String,
                                        warning_sink : Proc(String, Nil)?) : JSON::Any
      case on_denied
      when "error" then raise Error.new("Failed to access secret #{term} (AccessDenied)")
      when "warn"  then warning_sink.try(&.call("Skipping, access denied for secret #{term}"))
      end
      JSON::Any.new(nil)
    end

    # botocore's own ClientError.to_native text shape, which the plugin's
    # generic handler embeds after "Failed to retrieve secret: ".
    private def self.client_error_text(ex : AwsApiError, operation : String = "GetSecretValue") : String
      "An error occurred (#{ex.code}) when calling the #{operation} operation: #{ex.api_message}"
    end

    private def self.nested_value(secret_string : String, term : String, on_missing : String,
                                  warning_sink : Proc(String, Nil)?) : JSON::Any
      begin
        value = JSON.parse(secret_string)
      rescue ex : JSON::ParseException
        raise Error.new(ex.message || "invalid JSON secret")
      end
      path = ""
      term.split('.')[1..].each do |key|
        path = path.empty? ? key : "#{path}.#{key}"
        if (hash = value.as_h?) && hash.has_key?(key)
          value = hash[key]
          next
        end
        # on_missing drives a missing nested key exactly like a missing
        # secret; skip falls through and keeps walking the previous node.
        case on_missing
        when "warn"
          warning_sink.try(&.call("Skipping, Successfully retrieved secret but there exists no key #{path} in the secret"))
          return JSON::Any.new(nil)
        when "error"
          raise Error.new("Successfully retrieved secret but there exists no key #{path} in the secret")
        end
      end
      python_str(value)
    end

    private def self.python_str(value : JSON::Any) : JSON::Any
      return value if value.raw.is_a?(String)
      JSON::Any.new(python_repr(value.raw))
    end

    # Python str()'s repr shape for the nested walk's final value - a dict
    # renders "{'A': 'x', 'B': 'y'}" (single quotes), not JSON.
    private def self.python_repr(raw) : String
      case raw
      when Nil     then "None"
      when Bool    then raw ? "True" : "False"
      when Int64   then raw.to_s
      when Float64 then raw.to_s
      when String  then "'#{raw}'"
      when Array   then "[#{raw.map { |item| python_repr(item.raw) }.join(", ")}]"
      when Hash    then "{#{raw.map { |key, item| "'#{key}': #{python_repr(item.raw)}" }.join(", ")}}"
      else              raw.to_s
      end
    end
  end
end
