require "../spec_helper"
require "../../src/krikri/plugin_helpers/iam_api"
require "../../src/krikri/plugin_helpers/ec2_api"
require "xml"

# Unit-tests the IAM Query-API request/response handling against canned
# XML responses (the same transport-seam pattern the ec2_*_info specs
# use) - a real AWS account is not available in spec environments.
describe Krikri::PluginHelpers::IamApi do
  after_each do
    Krikri::PluginHelpers::IamApi.transport = nil
  end

  it "calls ListUsers with the IAM API version and PathPrefix" do
    captured = nil
    Krikri::PluginHelpers::IamApi.transport = ->(sent_body : String) do
      captured = sent_body
      <<-XML
        <ListUsersResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/">
          <ListUsersResult><IsTruncated>false</IsTruncated><Users/></ListUsersResult>
        </ListUsersResponse>
        XML
    end
    Krikri::PluginHelpers::IamApi.call("ListUsers", [{"PathPrefix", "/"}])
    captured.to_s.should contain("Action=ListUsers")
    captured.to_s.should contain("Version=2010-05-08")
    captured.to_s.should contain("PathPrefix=%2F")
  end

  it "surfaces API errors with code and message" do
    Krikri::PluginHelpers::IamApi.transport = ->(_sent_body : String) do
      <<-XML
        <ErrorResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/">
          <Error><Code>NoSuchEntity</Code><Message>The user with name missing cannot be found.</Message></Error>
        </ErrorResponse>
        XML
    end
    expect_raises(Krikri::PluginHelpers::IamApi::Error, "NoSuchEntity") do
      Krikri::PluginHelpers::IamApi.call("GetUser", {"UserName" => "missing"})
    end
  end

  it "navigates response children through the namespace-stripped names" do
    Krikri::PluginHelpers::IamApi.transport = ->(_sent_body : String) do
      <<-XML
        <GetUserResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/">
          <GetUserResult>
            <User>
              <user_name>test</user_name>
              <arn>arn:aws:iam::123456789012:user/test</arn>
            </User>
          </GetUserResult>
        </GetUserResponse>
        XML
    end
    root = Krikri::PluginHelpers::IamApi.call("GetUser", {"UserName" => "test"})
    result = Krikri::PluginHelpers::IamApi.child(root, "GetUserResult")
    user = result.try { |r| Krikri::PluginHelpers::IamApi.child(r, "User") }
    Krikri::PluginHelpers::IamApi.text(user.not_nil!, "arn").should eq("arn:aws:iam::123456789012:user/test")
  end

  it "walks truncated ListUsers pages via Marker" do
    pages = [
      %(<ListUsersResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/"><ListUsersResult><IsTruncated>true</IsTruncated><Marker>page2</Marker><Users><member><user_name>one</user_name></member></Users></ListUsersResult></ListUsersResponse>),
      %(<ListUsersResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/"><ListUsersResult><IsTruncated>false</IsTruncated><Users><member><user_name>two</user_name></member></Users></ListUsersResult></ListUsersResponse>),
    ]
    page_index = 0
    sent_markers = [] of String?
    Krikri::PluginHelpers::IamApi.transport = ->(sent_body : String) do
      sent_markers << (sent_body.includes?("Marker=") ? "marker" : nil)
      body = pages[page_index]
      page_index += 1
      body
    end

    names = [] of String
    Krikri::PluginHelpers::IamApi.each_page("ListUsers", ->(marker : String?) do
      params = [] of Tuple(String, String)
      params << {"Marker", marker} if marker
      params
    end) do |root|
      if list = Krikri::PluginHelpers::IamApi.child(root, "ListUsersResult")
        if set = Krikri::PluginHelpers::IamApi.child(list, "Users")
          Krikri::PluginHelpers::IamApi.children(set, "member").each do |member|
            names << Krikri::PluginHelpers::IamApi.text(member, "user_name").to_s
          end
        end
      end
    end
    names.should eq(["one", "two"])
    sent_markers.compact.size.should eq(1)
  end
end
