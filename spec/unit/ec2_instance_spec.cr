require "../spec_helper"
require "json"
require "../../src/krikri/plugin_helpers/ec2_api"
require "../../src/krikri/plugin_helpers/ec2_info"
require "../../src/krikri/plugin_helpers/ec2_instance"

# Decision-logic specs for amazon.aws.ec2_instance. Everything runs
# through the Ec2Api transport seam (no network): canned Describe/
# Run/Stop/Start/Terminate XML in, assertions on the shaped `instances`
# result, the changed flag, and the exact form bodies the module sends.
private DESCRIBE_RUNNING = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-1</requestId>
    <reservationSet>
      <item>
        <reservationId>r-1</reservationId>
        <ownerId>123456789012</ownerId>
        <instancesSet>
          <item>
            <instanceId>i-abc</instanceId>
            <imageId>ami-123</imageId>
            <instanceType>t3.micro</instanceType>
            <keyName>deploy</keyName>
            <launchTime>2026-09-10T00:00:00Z</launchTime>
            <instanceState><code>16</code><name>running</name></instanceState>
            <privateIpAddress>10.0.1.5</privateIpAddress>
            <ipAddress>54.0.0.1</ipAddress>
            <subnetId>subnet-aaaa</subnetId>
            <tagSet>
              <item><key>Name</key><value>web</value></item>
              <item><key>env</key><value>staging</value></item>
            </tagSet>
          </item>
        </instancesSet>
      </item>
    </reservationSet>
  </DescribeInstancesResponse>
XML

private DESCRIBE_STOPPED = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-2</requestId>
    <reservationSet>
      <item>
        <reservationId>r-2</reservationId>
        <ownerId>123456789012</ownerId>
        <instancesSet>
          <item>
            <instanceId>i-abc</instanceId>
            <imageId>ami-123</imageId>
            <instanceType>t3.micro</instanceType>
            <launchTime>2026-09-10T00:00:00Z</launchTime>
            <instanceState><code>80</code><name>stopped</name></instanceState>
            <subnetId>subnet-aaaa</subnetId>
            <tagSet>
              <item><key>Name</key><value>web</value></item>
            </tagSet>
          </item>
        </instancesSet>
      </item>
    </reservationSet>
  </DescribeInstancesResponse>
XML

private DESCRIBE_TERMINATED = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-term</requestId>
    <reservationSet>
      <item>
        <reservationId>r-1</reservationId>
        <ownerId>123456789012</ownerId>
        <instancesSet>
          <item>
            <instanceId>i-abc</instanceId>
            <imageId>ami-123</imageId>
            <instanceType>t3.micro</instanceType>
            <instanceState><code>48</code><name>terminated</name></instanceState>
          </item>
        </instancesSet>
      </item>
    </reservationSet>
  </DescribeInstancesResponse>
XML

private DESCRIBE_NONE = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-3</requestId>
    <reservationSet/>
  </DescribeInstancesResponse>
XML

private RUN_PENDING = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <RunInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-4</requestId>
    <reservationId>r-3</reservationId>
    <instancesSet>
      <item>
        <instanceId>i-new</instanceId>
        <instanceState><code>0</code><name>pending</name></instanceState>
      </item>
    </instancesSet>
  </RunInstancesResponse>
XML

private DESCRIBE_NEW_RUNNING = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-5</requestId>
    <reservationSet>
      <item>
        <reservationId>r-4</reservationId>
        <ownerId>123456789012</ownerId>
        <instancesSet>
          <item>
            <instanceId>i-new</instanceId>
            <imageId>ami-123</imageId>
            <instanceType>t3.micro</instanceType>
            <launchTime>2026-09-10T00:01:00Z</launchTime>
            <instanceState><code>16</code><name>running</name></instanceState>
            <subnetId>subnet-aaaa</subnetId>
            <tagSet>
              <item><key>Name</key><value>web</value></item>
            </tagSet>
          </item>
        </instancesSet>
      </item>
    </reservationSet>
  </DescribeInstancesResponse>
XML

private TERMINATED = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <TerminateInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-6</requestId>
    <instancesSet>
      <item>
        <instanceId>i-abc</instanceId>
        <instanceState><code>48</code><name>terminated</name></instanceState>
      </item>
    </instancesSet>
  </TerminateInstancesResponse>
XML

private STOPPING = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
    <requestId>req-7</requestId>
    <reservationSet>
      <item>
        <reservationId>r-8</reservationId>
        <ownerId>123456789012</ownerId>
        <instancesSet>
          <item>
            <instanceId>i-abc</instanceId>
            <instanceState><code>64</code><name>stopping</name></instanceState>
          </item>
        </instancesSet>
      </item>
    </reservationSet>
  </DescribeInstancesResponse>
XML

private def run_module(params : Hash(String, String), handler : Proc(String, String, String)) : JSON::Any
  Krikri::PluginHelpers::Ec2Api.transport = handler
  Krikri::PluginHelpers::Ec2Instance.poll_interval = 0.0
  begin
    result = Krikri::PluginHelpers::Ec2Instance.run(params)
    JSON.parse(result.to_json)
  ensure
    Krikri::PluginHelpers::Ec2Api.transport = nil
    Krikri::PluginHelpers::Ec2Instance.poll_interval = 5.0
  end
end

describe Krikri::PluginHelpers::Ec2Instance do
  around_each do |example|
    # The module resolves credentials from the environment - pin them so
    # the specs neither depend on the runner's real AWS env nor leak into
    # it.
    old_access = ENV["AWS_ACCESS_KEY_ID"]?
    old_secret = ENV["AWS_SECRET_ACCESS_KEY"]?
    ENV["AWS_ACCESS_KEY_ID"] = "test-access"
    ENV["AWS_SECRET_ACCESS_KEY"] = "test-secret"
    begin
      example.run
    ensure
      if old_access
        ENV["AWS_ACCESS_KEY_ID"] = old_access
      else
        ENV.delete("AWS_ACCESS_KEY_ID")
      end
      if old_secret
        ENV["AWS_SECRET_ACCESS_KEY"] = old_secret
      else
        ENV.delete("AWS_SECRET_ACCESS_KEY")
      end
    end
  end

  describe ".parse_instances" do
    it "reads reservationSet/instancesSet items and shapes the boto3 field names" do
      instances = Krikri::PluginHelpers::Ec2Instance.parse_instances(XML.parse(DESCRIBE_RUNNING).root.not_nil!)
      instances.size.should eq(1)
      inst = instances[0]
      inst.instance_id.should eq("i-abc")
      inst.state_name.should eq("running")
      inst.launch_time.should eq("2026-09-10T00:00:00Z")

      json = inst.json.as_h
      json["instance_id"].should eq("i-abc")
      json["image_id"].should eq("ami-123")
      json["instance_type"].should eq("t3.micro")
      json["key_name"].should eq("deploy")
      json["subnet_id"].should eq("subnet-aaaa")
      json["private_ip_address"].should eq("10.0.1.5")
      json["ip_address"].should eq("54.0.0.1")
      json["state"]["name"].should eq("running")
      json["state"]["code"].should eq("16")
      json["tags"]["Name"].should eq("web")
      json["tags"]["env"].should eq("staging")
    end

    it "returns an empty list for an empty reservationSet" do
      instances = Krikri::PluginHelpers::Ec2Instance.parse_instances(XML.parse(DESCRIBE_NONE).root.not_nil!)
      instances.should eq([] of Krikri::PluginHelpers::Ec2Instance::Instance)
    end
  end

  describe ".run" do
    it "creates a fresh instance, tags it, and waits for running" do
      bodies = [] of String
      describe_calls = 0
      # First DescribeInstances is the pre-create idempotency lookup (no
      # match yet); every one after that is a wait_for poll - once the
      # instance is created it's "running" immediately in this fixture,
      # so the very next poll must see it, or wait_for spins for real
      # wall-clock time (poll_interval is 0 in tests) until its 600s
      # default wait_timeout - a slow, CPU-burning false failure mode,
      # not a hang in the plugin itself.
      handler = ->(region : String, body : String) do
        bodies << body
        action = URI::Params.parse(body)["Action"]
        case action
        when "DescribeInstances"
          describe_calls += 1
          describe_calls == 1 ? DESCRIBE_NONE : DESCRIBE_NEW_RUNNING
        when "RunInstances" then RUN_PENDING
        else                      DESCRIBE_NEW_RUNNING
        end
      end
      result = run_module({
        "name"          => "web",
        "image_id"      => "ami-123",
        "instance_type" => "t3.micro",
        "key_name"      => "deploy",
        "vpc_subnet_id" => "subnet-aaaa",
        "user_data"     => "hello world",
        "tags"          => %({"env": "staging"}),
        "region"        => "us-east-1",
      }, handler)

      result["changed"].should eq(true)
      result["failed"].should eq(false)
      result["instances"][0]["instance_id"].should eq("i-new")
      result["instances"][0]["state"]["name"].should eq("running")

      run_body = bodies.find { |b| URI::Params.parse(b)["Action"] == "RunInstances" }.not_nil!
      run_params = URI::Params.parse(run_body)
      run_params["ImageId"].should eq("ami-123")
      run_params["InstanceType"].should eq("t3.micro")
      run_params["KeyName"].should eq("deploy")
      run_params["SubnetId"].should eq("subnet-aaaa")
      run_params["MinCount"].should eq("1")
      run_params["MaxCount"].should eq("1")
      run_params["UserData"].should eq(Base64.strict_encode("hello world"))

      tag_body = bodies.find { |b| URI::Params.parse(b)["Action"] == "CreateTags" }.not_nil!
      tag_params = URI::Params.parse(tag_body)
      tag_params["ResourceId.1"].should eq("i-new")
      tag_params.fetch_all("Tag.1.Key").should eq(["Name"])
      tag_params["Tag.1.Value"].should eq("web")
      tag_params.fetch_all("Tag.2.Key").should eq(["env"])
      tag_params["Tag.2.Value"].should eq("staging")

      describe_bodies = bodies.select { |b| URI::Params.parse(b)["Action"] == "DescribeInstances" }
      describe_bodies.size.should eq(2)
    end

    it "is a no-op when a match already exists in the target state" do
      bodies = [] of String
      handler = ->(region : String, body : String) do
        bodies << body
        DESCRIBE_RUNNING
      end
      result = run_module({"name" => "web", "image_id" => "ami-123", "instance_type" => "t3.micro", "region" => "us-east-1"}, handler)

      result["changed"].should eq(false)
      result["instances"][0]["instance_id"].should eq("i-abc")
      actions = bodies.map { |b| URI::Params.parse(b)["Action"] }
      actions.should eq(["DescribeInstances"])
    end

    it "sends the tag:Name and non-terminated state filters on the idempotency lookup" do
      bodies = [] of String
      handler = ->(region : String, body : String) do
        bodies << body
        DESCRIBE_RUNNING
      end
      run_module({"name" => "web", "region" => "us-east-1"}, handler)

      body = bodies.first.not_nil!
      params = URI::Params.parse(body)
      params.fetch_all("Filter.1.Name").should eq(["tag:Name"])
      params.fetch_all("Filter.1.Value.1").should eq(["web"])
      params.fetch_all("Filter.2.Name").should eq(["instance-state-name"])
      params.fetch_all("Filter.2.Value.1").should eq(["pending"])
      params.fetch_all("Filter.2.Value.2").should eq(["running"])
      params.fetch_all("Filter.2.Value.3").should eq(["stopping"])
      params.fetch_all("Filter.2.Value.4").should eq(["stopped"])
    end

    it "terminates an existing match for state=absent" do
      bodies = [] of String
      describe_calls = 0
      handler = ->(region : String, body : String) do
        bodies << body
        action = URI::Params.parse(body)["Action"]
        if action == "DescribeInstances"
          describe_calls += 1
          # First call is the pre-terminate idempotency lookup (finds the
          # running match); real EC2 keeps a terminated instance visible
          # in DescribeInstances with state=terminated for a while after
          # termination (it doesn't disappear immediately).
          describe_calls == 1 ? DESCRIBE_RUNNING : DESCRIBE_TERMINATED
        else
          TERMINATED
        end
      end
      result = run_module({"name" => "web", "state" => "absent", "region" => "us-east-1"}, handler)

      result["changed"].should eq(true)
      term_body = bodies.find { |b| URI::Params.parse(b)["Action"] == "TerminateInstances" }.not_nil!
      URI::Params.parse(term_body)["InstanceId.1"].should eq("i-abc")
      result["instances"][0]["state"]["name"].should eq("terminated")
    end

    it "is a no-op for state=absent when nothing matches" do
      result = run_module({"name" => "web", "state" => "absent", "region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_NONE })
      result["changed"].should eq(false)
      result["msg"].should eq("no matching instances found")
    end

    it "starts a stopped match for state=running" do
      bodies = [] of String
      describe_calls = 0
      handler = ->(region : String, body : String) do
        bodies << body
        action = URI::Params.parse(body)["Action"]
        if action == "DescribeInstances"
          describe_calls += 1
          # First call is the pre-start idempotency lookup (finds the
          # stopped match); the wait loop's own polls after StartInstances
          # need to see it reach "running".
          describe_calls == 1 ? DESCRIBE_STOPPED : DESCRIBE_RUNNING
        else
          DESCRIBE_RUNNING
        end
      end
      result = run_module({"name" => "web", "state" => "running", "region" => "us-east-1"}, handler)

      result["changed"].should eq(true)
      start_body = bodies.find { |b| URI::Params.parse(b)["Action"] == "StartInstances" }.not_nil!
      URI::Params.parse(start_body)["InstanceId.1"].should eq("i-abc")
      result["instances"][0]["state"]["name"].should eq("running")
    end

    it "stops a running match for state=stopped, polling until stopped" do
      bodies = [] of String
      describe_count = 0
      handler = ->(region : String, body : String) do
        bodies << body
        action = URI::Params.parse(body)["Action"]
        if action == "DescribeInstances"
          describe_count += 1
          # Call 1 is the pre-stop idempotency lookup (finds the running
          # match); call 2 is the wait loop's first poll (still
          # stopping - exercises its continue path); call 3+ sees the
          # target state.
          case describe_count
          when 1 then DESCRIBE_RUNNING
          when 2 then STOPPING
          else        DESCRIBE_STOPPED
          end
        else
          DESCRIBE_STOPPED
        end
      end
      result = run_module({"name" => "web", "state" => "stopped", "region" => "us-east-1"}, handler)

      result["changed"].should eq(true)
      stop_body = bodies.find { |b| URI::Params.parse(b)["Action"] == "StopInstances" }.not_nil!
      URI::Params.parse(stop_body)["InstanceId.1"].should eq("i-abc")
      result["instances"][0]["state"]["name"].should eq("stopped")
      describe_count.should eq(3)
    end

    it "restarts a running instance for state=restarted" do
      bodies = [] of String
      handler = ->(region : String, body : String) do
        bodies << body
        action = URI::Params.parse(body)["Action"]
        action == "DescribeInstances" ? DESCRIBE_RUNNING : DESCRIBE_NEW_RUNNING
      end
      result = run_module({"name" => "web", "state" => "restarted", "region" => "us-east-1"}, handler)

      result["changed"].should eq(true)
      actions = bodies.map { |b| URI::Params.parse(b)["Action"] }
      actions.should contain("StopInstances")
      actions.should contain("StartInstances")
    end

    it "launches the difference for exact_count below the target" do
      bodies = [] of String
      describe_calls = 0
      handler = ->(region : String, body : String) do
        bodies << body
        action = URI::Params.parse(body)["Action"]
        if action == "DescribeInstances"
          describe_calls += 1
          # First call is the pre-launch existing-count lookup (finds the
          # 1 running match); the wait loop's own polls after RunInstances
          # need to see the newly-launched instance ("i-new") running.
          describe_calls == 1 ? DESCRIBE_RUNNING : DESCRIBE_NEW_RUNNING
        else
          RUN_PENDING
        end
      end
      result = run_module({
        "name"        => "web",
        "exact_count" => "3",
        "image_id"    => "ami-123",
        "region"      => "us-east-1",
      }, handler)

      result["changed"].should eq(true)
      run_body = bodies.find { |b| URI::Params.parse(b)["Action"] == "RunInstances" }.not_nil!
      URI::Params.parse(run_body)["MaxCount"].should eq("2")
      result["msg"].as_s.should contain("exact_count 3")
    end

    it "is a no-op for exact_count already met" do
      result = run_module({
        "name"        => "web",
        "exact_count" => "1",
        "image_id"    => "ami-123",
        "region"      => "us-east-1",
      }, ->(region : String, body : String) { DESCRIBE_RUNNING })
      result["changed"].should eq(false)
    end

    it "purges tags not in the desired set (aws: reserved keys spared)" do
      bodies = [] of String
      handler = ->(region : String, body : String) do
        bodies << body
        DESCRIBE_RUNNING
      end
      result = run_module({
        "name"   => "web",
        "tags"   => %({"Name": "web", "team": "infra"}),
        "region" => "us-east-1",
      }, handler)

      result["changed"].should eq(true)
      create_body = bodies.find { |b| URI::Params.parse(b)["Action"] == "CreateTags" }.not_nil!
      create_params = URI::Params.parse(create_body)
      create_params["ResourceId.1"].should eq("i-abc")
      create_params["Tag.1.Key"].should eq("team")
      create_params["Tag.1.Value"].should eq("infra")

      delete_body = bodies.find { |b| URI::Params.parse(b)["Action"] == "DeleteTags" }.not_nil!
      delete_params = URI::Params.parse(delete_body)
      delete_params.fetch_all("Tag.1.Key").should eq(["env"])
    end

    it "fails when no targeting param is given" do
      result = run_module({"state" => "present", "region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_NONE })
      result["failed"].should eq(true)
      result["msg"].as_s.should contain("required")
    end

    it "fails on an invalid state" do
      result = run_module({"name" => "web", "state" => "paused", "region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_NONE })
      result["failed"].should eq(true)
      result["msg"].as_s.should contain("state")
    end

    it "fails when creating without image_id" do
      result = run_module({"name" => "web", "instance_type" => "t3.micro", "region" => "us-east-1"}, ->(region : String, body : String) { DESCRIBE_NONE })
      result["failed"].should eq(true)
      result["msg"].as_s.should contain("image_id")
    end

    it "fails with the API error message when a call errors" do
      result = run_module({"name" => "web", "region" => "us-east-1"}, ->(region : String, body : String) { raise Krikri::PluginHelpers::Ec2Api::Error.new("UnauthorizedOperation: fake") })
      result["failed"].should eq(true)
      result["msg"].should eq("UnauthorizedOperation: fake")
    end

    it "reports the plan in check mode without executing it" do
      bodies = [] of String
      handler = ->(region : String, body : String) do
        bodies << body
        action = URI::Params.parse(body)["Action"]
        action == "DescribeInstances" ? DESCRIBE_NONE : RUN_PENDING
      end
      result = run_module({
        "name"       => "web",
        "image_id"   => "ami-123",
        "region"     => "us-east-1",
        "check_mode" => "true",
      }, handler)

      result["changed"].should eq(true)
      result["msg"].as_s.should contain("check mode")
      actions = bodies.map { |b| URI::Params.parse(b)["Action"] }
      actions.should eq(["DescribeInstances"])
    end
  end
end
