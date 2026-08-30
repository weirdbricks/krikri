#!/usr/bin/env crystal

require "json"
require "http/client"
require "uri"
require "../src/krikri/base_plugin"

module Krikri
  # ec2_metadata_facts plugin - populates ansible_ec2_* facts from the
  # EC2 Instance Metadata Service (IMDSv2). Compatible with (a subset
  # of) Ansible's amazon.aws.ec2_metadata_facts module.
  #
  # Native HTTP::Client, same rationale as uri.cr/get_url.cr's own doc
  # comments: this plugin binary already runs on whichever host (local
  # or remote, via PluginManager's own upload+exec) the task targets, so
  # the request to the link-local 169.254.169.254 endpoint naturally
  # comes from the right place - no remote_exec fallback needed. Only
  # meaningful when run ON a real EC2 instance (real Ansible's own
  # module has the identical restriction - IMDS doesn't exist off-EC2).
  #
  # Mirrors the real module's algorithm closely: fetch an IMDSv2 session
  # token, then recursively walk the meta-data/ and dynamic/ trees the
  # same way (a GET on a directory path returns a newline-separated
  # listing; each non-directory leaf is fetched and, if its content
  # parses as a JSON object, each of ITS top-level keys is *also*
  # flattened into its own fact under "<leaf>:<key.downcase>" - e.g.
  # dynamic/instance-identity/document's own "accountId" JSON key
  # becomes ansible_ec2_instance_identity_document_accountid).
  #
  # Not implemented: gzip/zlib-compressed user-data decoding (real
  # Ansible's own decode_user_data - an edge case for cloud-init
  # payloads compressed at upload time, not the common case).
  class Ec2MetadataFactsPlugin < BasePlugin
    TOKEN_URI = "http://169.254.169.254/latest/api/token"
    META_URI  = "http://169.254.169.254/latest/meta-data/"
    TAGS_URI  = "http://169.254.169.254/latest/meta-data/tags/instance"
    SSH_URI   = "http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key"
    USER_URI  = "http://169.254.169.254/latest/user-data/"
    DYN_URI   = "http://169.254.169.254/latest/dynamic/"

    class FetchError < Exception; end

    def execute : PluginResult
      ttl = (@params["metadata_token_ttl_seconds"]? || "60").to_i
      unless (1..21600).covers?(ttl)
        return PluginResult.new(changed: false, failed: true, msg: "The option 'metadata_token_ttl_seconds' must be set to a value between 1 and 21600.")
      end

      facts = gather_facts(ttl)
      PluginResult.new(changed: false, failed: false, msg: "Gathered EC2 metadata facts", ansible_facts: JSON::Any.new(facts))
    rescue ex : FetchError
      PluginResult.new(changed: false, failed: true, msg: ex.message || "Failed to retrieve metadata from AWS")
    rescue ex : Socket::ConnectError | Socket::Addrinfo::Error | IO::TimeoutError
      PluginResult.new(changed: false, failed: true, msg: "Could not reach the EC2 metadata service (169.254.169.254) - this module only works when run on a real EC2 instance: #{ex.message}")
    end

    private def gather_facts(ttl : Int32) : Hash(String, JSON::Any)
      token = fetch_token(ttl)

      meta_raw = Hash(String, JSON::Any).new
      fetch_tree(META_URI, META_URI, token, meta_raw)
      facts = mangle_fields(meta_raw, META_URI)
      facts["ansible_ec2_user-data"] = JSON::Any.new(fetch_raw(USER_URI, token))
      facts["ansible_ec2_public-key"] = JSON::Any.new(fetch_raw(SSH_URI, token))

      dyn_raw = Hash(String, JSON::Any).new
      fetch_tree(DYN_URI, DYN_URI, token, dyn_raw)
      mangle_fields(dyn_raw, DYN_URI).each { |key, value| facts[key] = value }

      facts = fix_invalid_varnames(facts)
      apply_instance_tags(facts, token)

      if region = facts["ansible_ec2_instance_identity_document_region"]?
        facts["ansible_ec2_placement_region"] = region
      end

      facts
    end

    private def apply_instance_tags(facts : Hash(String, JSON::Any), token : String)
      raw = fetch_raw(TAGS_URI, token)
      tag_keys = raw == "None" ? [] of String : raw.split('\n').reject(&.empty?)
      facts["ansible_ec2_instance_tags_keys"] = JSON::Any.new(tag_keys.map { |key| JSON::Any.new(key) })

      tags = Hash(String, JSON::Any).new
      # Matches real Ansible's own get_instance_tags: looks up the RAW
      # (un-mangled) tag key against the already fix_invalid_varnames'd
      # facts dict - a hyphenated tag name would genuinely miss here in
      # real Ansible too, not a bug introduced by this port.
      tag_keys.each do |key|
        value = facts["ansible_ec2_tags_instance_#{key}"]?
        tags[key] = value if value
      end
      facts["ansible_ec2_instance_tags"] = JSON::Any.new(tags)
    end

    # Matches real Ansible's own _mangle_fields: turns a raw {full URL =>
    # content} map into {"ansible_ec2_<dash-joined-relative-path>" =>
    # content}, plus the one special case (an IAM security-credentials
    # role directory) that also gets a synthetic "iam-instance-profile-
    # role" fact, and a filter dropping any "public-keys-0" fact (the
    # instance's default SSH key gets its own dedicated
    # ansible_ec2_public-key fact instead, fetched separately).
    private def mangle_fields(data : Hash(String, JSON::Any), uri : String) : Hash(String, JSON::Any)
      new_fields = Hash(String, JSON::Any).new
      data.each do |key, value|
        split_fields = key[uri.size..].split('/')

        if split_fields.size == 3 && split_fields[0] == "iam" && split_fields[1] == "security-credentials" && !split_fields[2].includes?(':')
          new_fields["ansible_ec2_iam-instance-profile-role"] = JSON::Any.new(split_fields[2])
        end

        new_key = split_fields.size > 1 && !split_fields[1].empty? ? split_fields.join('-') : split_fields.join("")
        new_fields["ansible_ec2_#{new_key}"] = value
      end

      new_fields.reject! { |key, _| key.includes?("public-keys-0") }
      new_fields
    end

    private def fix_invalid_varnames(data : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      new_data = Hash(String, JSON::Any).new
      data.each { |key, value| new_data[key.gsub(/[:\-]/, "_")] = value }
      new_data
    end

    # Recursively walks a metadata directory the same way real Ansible's
    # own #fetch does: a GET on a directory-shaped URI returns a
    # newline-separated listing of child names (subdirectories end in
    # "/"); each leaf gets fetched and stored, with a JSON-object leaf
    # ALSO exploded into "<leaf>:<lowercased key>" sub-entries.
    private def fetch_tree(uri : String, base : String, token : String, data : Hash(String, JSON::Any))
      raw = fetch_raw(uri, token)
      return if raw.empty? || raw == "None"

      raw.split('\n').each do |field|
        next if field.empty?
        fetch_tree(uri + field, base, token, data) if field.ends_with?('/')

        new_uri = uri.ends_with?('/') ? uri + field : "#{uri}/#{field}"
        next if data.has_key?(new_uri) || new_uri.ends_with?('/')

        store_leaf(data, new_uri, field, fetch_raw(new_uri, token))
      end
    end

    private def store_leaf(data : Hash(String, JSON::Any), new_uri : String, field : String, content : String)
      if field == "security-groups" || field == "security-group-ids"
        data[new_uri] = JSON::Any.new(content.split('\n').join(","))
        return
      end

      data[new_uri] = JSON::Any.new(content)
      begin
        parsed = JSON.parse(content)
        parsed.as_h?.try(&.each { |key, value| data["#{new_uri}:#{key.downcase}"] = value })
      rescue
      end
    end

    private def fetch_token(ttl : Int32) : String
      response = put_with_retry(TOKEN_URI, {"X-aws-ec2-metadata-token-ttl-seconds" => ttl.to_s}, "metadata token")
      response.status_code < 400 ? response.body : "None"
    end

    private def fetch_raw(url : String, token : String) : String
      headers = token.empty? ? HTTP::Headers.new : HTTP::Headers{"X-aws-ec2-metadata-token" => token}
      response = get_with_retry(url, headers)
      response.status_code < 400 ? response.body : "None"
    end

    private def get_with_retry(url : String, headers : HTTP::Headers) : HTTP::Client::Response
      with_retry("metadata") { request(url, "GET", headers) }
    end

    private def put_with_retry(url : String, headers : Hash(String, String), label : String) : HTTP::Client::Response
      http_headers = HTTP::Headers.new
      headers.each { |key, value| http_headers[key] = value }
      with_retry(label) { request(url, "PUT", http_headers) }
    end

    # Matches real Ansible's own retry policy: a 401/403 fails
    # immediately (an auth problem retrying won't fix), any other
    # non-200/404 status gets ONE retry after a short pause, and only
    # THEN gives up.
    private def with_retry(label : String, & : -> HTTP::Client::Response) : HTTP::Client::Response
      response = yield
      return response if response.status_code == 200 || response.status_code == 404
      raise FetchError.new("Failed to retrieve #{label} from AWS: HTTP #{response.status_code}") if response.status_code == 401 || response.status_code == 403

      sleep 3.seconds
      response = yield
      return response if response.status_code == 200 || response.status_code == 404

      raise FetchError.new("Failed to retrieve #{label} from AWS: HTTP #{response.status_code}")
    end

    private def request(url : String, method : String, headers : HTTP::Headers) : HTTP::Client::Response
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 5.seconds
      client.read_timeout = 5.seconds
      client.exec(method, uri.request_target, headers: headers)
    ensure
      client.try(&.close)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::Ec2MetadataFactsPlugin.new(config)
plugin.run
