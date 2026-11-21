require "../minitest_helper"
require "../../src/krikri/ssm_unreachable_msg"
require "../../src/krikri/ssh_manager"

private def ssm_api_error(klass : KrikriAwsSsm::ApiError.class, code : String, message : String)
  klass.new(code, message)
end

describe Krikri::SsmUnreachableMsg do
  it "maps each typed shard error to an actionable SSM line" do
    target = Krikri::SsmUnreachableMsg.unreachable_text(
      ssm_api_error(KrikriAwsSsm::TargetNotConnected, "TargetNotConnected", "instance i-123 is not connected"))
    target.must_equal("#{Krikri::SsmUnreachableMsg::TARGET_NOT_CONNECTED}: instance i-123 is not connected")

    credentials = Krikri::SsmUnreachableMsg.unreachable_text(KrikriAwsSsm::CredentialsError.new)
    credentials.must_equal(Krikri::SsmUnreachableMsg::NO_CREDENTIALS)
    credentials.includes?("Unable to locate credentials").must_equal(true)

    denied = Krikri::SsmUnreachableMsg.unreachable_text(
      ssm_api_error(KrikriAwsSsm::AccessDenied, "AccessDeniedException", "not authorized"))
    denied.must_equal("#{Krikri::SsmUnreachableMsg::ACCESS_DENIED}: not authorized")

    document = Krikri::SsmUnreachableMsg.unreachable_text(
      ssm_api_error(KrikriAwsSsm::InvalidDocument, "InvalidDocument", "bad document"))
    document.must_equal("#{Krikri::SsmUnreachableMsg::INVALID_DOCUMENT}: bad document")

    session = Krikri::SsmUnreachableMsg.unreachable_text(
      ssm_api_error(KrikriAwsSsm::SessionNotFound, "SessionNotFound", "gone"))
    session.must_equal("#{Krikri::SsmUnreachableMsg::SESSION_NOT_FOUND}: gone")

    timeout = Krikri::SsmUnreachableMsg.unreachable_text(KrikriAwsSsm::SessionTimeout.new("idle"))
    timeout.must_equal("#{Krikri::SsmUnreachableMsg::SESSION_TIMEOUT}: idle")

    handshake = Krikri::SsmUnreachableMsg.unreachable_text(KrikriAwsSsm::HandshakeFailed.new("refused"))
    handshake.must_equal("#{Krikri::SsmUnreachableMsg::HANDSHAKE_FAILED}: refused")

    closed = Krikri::SsmUnreachableMsg.unreachable_text(KrikriAwsSsm::ChannelClosed.new("agent closed"))
    closed.must_equal("#{Krikri::SsmUnreachableMsg::CHANNEL_CLOSED}: agent closed")
  end

  it "maps close reasons that carry no exception" do
    Krikri::SsmUnreachableMsg.for_close(KrikriAwsSsm::CloseReason::SessionTimeout)
      .must_equal(Krikri::SsmUnreachableMsg::SESSION_TIMEOUT)
    Krikri::SsmUnreachableMsg.for_close(KrikriAwsSsm::CloseReason::AgentClosed)
      .must_equal(Krikri::SsmUnreachableMsg::CHANNEL_CLOSED)
    Krikri::SsmUnreachableMsg.for_close(KrikriAwsSsm::CloseReason::NetworkLost)
      .must_equal(Krikri::SsmUnreachableMsg::NETWORK_LOST)
    Krikri::SsmUnreachableMsg.for_close(KrikriAwsSsm::CloseReason::ProtocolError)
      .must_equal(Krikri::SsmUnreachableMsg::PROTOCOL_ERROR)
  end

  it "prefixes every transport-level line so SSH's classifier books it" do
    text = Krikri::SsmUnreachableMsg.unreachable_text(KrikriAwsSsm::CredentialsError.new)
    Krikri::SsmUnreachableMsg.unreachable_text?(text).must_equal(true)
    Krikri::SSHManager.connection_level_exception?(Exception.new(text)).must_equal(true)
    Krikri::SSHManager.connection_level_failure?(255, text).must_equal(true)
    Krikri::SSHManager.connection_level_failure?(255, Krikri::SsmUnreachableMsg::WINDOWS_UNSUPPORTED).must_equal(true)
    Krikri::SsmUnreachableMsg.windows_text?(Krikri::SsmUnreachableMsg::WINDOWS_UNSUPPORTED).must_equal(true)
  end
end
