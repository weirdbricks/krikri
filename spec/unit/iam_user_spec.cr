require "../spec_helper"
require "json"
require "../../src/krikri/plugin_helpers/iam_api"
require "../../src/krikri/plugin_helpers/iam_user"

# Regression specs for amazon.aws.iam_user_info's user shaping, run
# through the IamApi transport seam (no network). The canned XML uses
# the REAL wire shape observed live (aws iam get-user / the Query API):
# PascalCase element names (UserName/Arn/CreateDate/UserId/Path) inside
# GetUserResult/User, ListUserTags members with Key/Value, and an
# ErrorResponse for GetLoginProfile when the user has no console
# access. A previous version read snake_case element names off this
# XML and dropped every user field as a result.
private GET_USER = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <GetUserResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/">
    <GetUserResult>
      <User>
        <Path>/division_abc/subdivision_xyz/</Path>
        <UserName>lchaidas</UserName>
        <UserId>AIDAYIK7BAUYMSODPFEOZ</UserId>
        <Arn>arn:aws:iam::567671850288:user/lchaidas</Arn>
        <CreateDate>2022-02-17T19:56:59Z</CreateDate>
        <PasswordLastUsed>2026-09-01T10:00:00Z</PasswordLastUsed>
      </User>
    </GetUserResult>
    <ResponseMetadata><RequestId>req-1</RequestId></ResponseMetadata>
  </GetUserResponse>
XML

private USER_TAGS = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <ListUserTagsResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/">
    <ListUserTagsResult>
      <IsTruncated>false</IsTruncated>
      <Tags>
        <member><Key>team</Key><Value>platform</Value></member>
        <member><Key>env</Key><Value>test</Value></member>
      </Tags>
    </ListUserTagsResult>
  </ListUserTagsResponse>
XML

private NO_LOGIN_PROFILE = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <ErrorResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/">
    <Error><Code>NoSuchEntity</Code><Message>Login Profile for user lchaidas cannot be found.</Message></Error>
  </ErrorResponse>
XML

private LOGIN_PROFILE = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <GetLoginProfileResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/">
    <GetLoginProfileResult>
      <LoginProfile>
        <UserName>lchaidas</UserName>
        <CreateDate>2026-01-01T00:00:00Z</CreateDate>
        <PasswordResetRequired>true</PasswordResetRequired>
      </LoginProfile>
    </GetLoginProfileResult>
  </GetLoginProfileResponse>
XML

private LIST_USERS = <<-XML
  <?xml version="1.0" encoding="UTF-8"?>
  <ListUsersResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/">
    <ListUsersResult>
      <IsTruncated>false</IsTruncated>
      <Users>
        <member>
          <Path>/</Path>
          <UserName>lchaidas</UserName>
          <UserId>AIDAYIK7BAUYMSODPFEOZ</UserId>
          <Arn>arn:aws:iam::567671850288:user/lchaidas</Arn>
          <CreateDate>2022-02-17T19:56:59Z</CreateDate>
        </member>
        <member>
          <Path>/service/</Path>
          <UserName>ci-bot</UserName>
          <UserId>AIDAYIK7BAUYOTHERUSR</UserId>
          <Arn>arn:aws:iam::567671850288:user/service/ci-bot</Arn>
          <CreateDate>2023-05-01T00:00:00Z</CreateDate>
        </member>
      </Users>
    </ListUsersResult>
  </ListUsersResponse>
XML

private def run_module(params : Hash(String, String), handler : Proc(String, String)) : JSON::Any
  Krikri::PluginHelpers::IamApi.transport = handler
  begin
    result = Krikri::PluginHelpers::IamUser.run(params)
    JSON.parse(result.to_json)
  ensure
    Krikri::PluginHelpers::IamApi.transport = nil
  end
end

describe Krikri::PluginHelpers::IamUser do
  describe ".run" do
    it "shapes a GetUser result with the real module's fields, tags and login_profile" do
      result = run_module({"name" => "lchaidas"}, ->(body : String) do
        case URI::Params.parse(body)["Action"]
        when "GetUser"         then GET_USER
        when "ListUserTags"    then USER_TAGS
        when "GetLoginProfile" then NO_LOGIN_PROFILE
        else                        raise "unexpected body #{body}"
        end
      end)

      result["failed"]?.should be_falsey
      result["msg"]?.should be_nil
      user = result["iam_users"][0]
      user["arn"].should eq("arn:aws:iam::567671850288:user/lchaidas")
      user["create_date"].should eq("2022-02-17T19:56:59+00:00")
      user["path"].should eq("/division_abc/subdivision_xyz/")
      user["user_id"].should eq("AIDAYIK7BAUYMSODPFEOZ")
      user["user_name"].should eq("lchaidas")
      user["password_last_used"].should eq("2026-09-01T10:00:00+00:00")
      user["tags"]["team"].should eq("platform")
      user["tags"]["env"].should eq("test")
      user["login_profile"].as_h.should be_empty
    end

    it "shapes a login_profile with snake_case keys when the user has console access" do
      result = run_module({"name" => "lchaidas"}, ->(body : String) do
        case URI::Params.parse(body)["Action"]
        when "GetUser"         then GET_USER
        when "ListUserTags"    then USER_TAGS
        when "GetLoginProfile" then LOGIN_PROFILE
        else                        raise "unexpected body #{body}"
        end
      end)

      profile = result["iam_users"][0]["login_profile"]
      profile["user_name"].should eq("lchaidas")
      profile["create_date"].should eq("2026-01-01T00:00:00+00:00")
      profile["password_reset_required"].should be_true
    end

    it "walks ListUsers by path_prefix when no name is given" do
      result = run_module({"path_prefix" => "/"}, ->(_body : String) do
        LIST_USERS
      end)

      users = result["iam_users"].as_a
      users.size.should eq(2)
      users[0]["user_name"].should eq("lchaidas")
      users[0]["arn"].should eq("arn:aws:iam::567671850288:user/lchaidas")
      users[1]["user_name"].should eq("ci-bot")
    end

    it "returns an empty result for a missing user (NoSuchEntity, not a failure)" do
      result = run_module({"name" => "missing"}, ->(_body : String) do
        raise Krikri::PluginHelpers::IamApi::Error.new("IAM GetUser: NoSuchEntity: The user with name missing cannot be found.")
      end)
      result["failed"]?.should be_falsey
      result["iam_users"].as_a.should be_empty
    end

    it "fails with the API error message on non-NoSuchEntity errors" do
      result = run_module({"name" => "lchaidas"}, ->(_body : String) do
        raise Krikri::PluginHelpers::IamApi::Error.new("IAM GetUser: AccessDenied: not authorized")
      end)
      result["failed"].should be_true
      result["msg"].as_s.should contain("AccessDenied")
    end
  end
end
