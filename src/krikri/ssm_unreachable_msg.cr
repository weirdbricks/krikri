require "krikri-aws-ssm"
require "./ssm_settings"

module Krikri
  # The typed-error translator for the SSM transport (plan 6.7).
  #
  # The shard raises typed exceptions (TargetNotConnected, CredentialsError,
  # AccessDenied, ...) and reports a typed CloseReason. krikri's task result
  # layer treats a 255 exit as UNREACHABLE and an exception as an unhandled
  # engine error unless it recognizes the message, so every SSM transport
  # failure is composed here into one stable, actionable line with the
  # "SSM " prefix. SSHUnreachableMsg's ssh wordings are deliberately
  # untouched.
  module SsmUnreachableMsg
    PREFIX = "SSM "

    TARGET_NOT_CONNECTED =
      "#{PREFIX}target is not connected: the instance is not registered with Session Manager or its SSM agent is not running"
    NO_CREDENTIALS =
      "#{PREFIX}credentials: Unable to locate credentials"
    ACCESS_DENIED =
      "#{PREFIX}access denied: check ssm:StartSession/ResumeSession/TerminateSession permissions"
    INVALID_DOCUMENT =
      "#{PREFIX}session document is invalid"
    SESSION_NOT_FOUND =
      "#{PREFIX}session was not found (it may already have ended)"
    SESSION_TIMEOUT =
      "#{PREFIX}session timed out (idle timeout or session lifetime cap)"
    HANDSHAKE_FAILED =
      "#{PREFIX}session handshake failed"
    CHANNEL_CLOSED =
      "#{PREFIX}session was closed by the agent"
    NETWORK_LOST =
      "#{PREFIX}session was lost: the network connection dropped"
    PROTOCOL_ERROR =
      "#{PREFIX}protocol error"
    CONFIGURATION_ERROR =
      "#{PREFIX}configuration error"

    # The pure Windows guard is an action failure, not a connectivity one.
    WINDOWS_UNSUPPORTED = SsmSettings::WINDOWS_UNSUPPORTED_MESSAGE

    # The krikri unreachable text for *ex*.
    def self.unreachable_text(ex : Exception) : String
      return api_error_text(ex) if ex.is_a?(KrikriAwsSsm::ApiError)

      case ex
      when KrikriAwsSsm::CredentialsError
        # The shard's default is already "Unable to locate credentials";
        # keep that exact phrase visible without repeating it.
        message = ex.message.to_s
        message.includes?("Unable to locate credentials") ? NO_CREDENTIALS : with_detail(NO_CREDENTIALS, message)
      when KrikriAwsSsm::SessionTimeout
        with_detail(SESSION_TIMEOUT, ex.message)
      when KrikriAwsSsm::HandshakeFailed
        with_detail(HANDSHAKE_FAILED, ex.message)
      when KrikriAwsSsm::ChannelClosed
        with_detail(CHANNEL_CLOSED, ex.message)
      when KrikriAwsSsm::ConfigurationError
        with_detail(CONFIGURATION_ERROR, ex.message)
      when KrikriAwsSsm::ProtocolError
        with_detail(PROTOCOL_ERROR, ex.message)
      else
        with_detail("#{PREFIX}transport error", ex.message || ex.class.name)
      end
    end

    private def self.api_error_text(ex : KrikriAwsSsm::ApiError) : String
      case ex
      when KrikriAwsSsm::TargetNotConnected
        with_detail(TARGET_NOT_CONNECTED, api_detail(ex))
      when KrikriAwsSsm::AccessDenied
        with_detail(ACCESS_DENIED, api_detail(ex))
      when KrikriAwsSsm::InvalidDocument
        with_detail(INVALID_DOCUMENT, api_detail(ex))
      when KrikriAwsSsm::SessionNotFound
        with_detail(SESSION_NOT_FOUND, api_detail(ex))
      else
        with_detail("#{PREFIX}transport error", ex.message)
      end
    end

    # The krikri text for a session that closed without an exception.
    def self.for_close(reason : KrikriAwsSsm::CloseReason?,
                       error : Exception? = nil) : String
      return unreachable_text(error) if error
      case reason
      when KrikriAwsSsm::CloseReason::SessionTimeout
        SESSION_TIMEOUT
      when KrikriAwsSsm::CloseReason::AgentClosed, KrikriAwsSsm::CloseReason::Clean
        CHANNEL_CLOSED
      when KrikriAwsSsm::CloseReason::NetworkLost
        NETWORK_LOST
      when KrikriAwsSsm::CloseReason::ProtocolError
        PROTOCOL_ERROR
      when KrikriAwsSsm::CloseReason::Terminated
        "#{PREFIX}session was terminated"
      else
        "#{PREFIX}session closed"
      end
    end

    # True for a message this module composed, i.e. an SSM transport-level
    # failure the result layer should book like an SSH transport failure.
    def self.unreachable_text?(text : String) : Bool
      text.starts_with?(PREFIX)
    end

    def self.windows_text?(text : String) : Bool
      text == WINDOWS_UNSUPPORTED
    end

    private def self.api_detail(ex : KrikriAwsSsm::ApiError) : String
      message = ex.message.to_s
      prefix = "#{ex.code}: "
      message.starts_with?(prefix) ? message[prefix.size..] : message
    end

    private def self.with_detail(base : String, detail : String?) : String
      text = detail.to_s.strip
      return base if text.empty? || base.ends_with?(text)
      text = text.lchop(PREFIX)
      "#{base}: #{text}"
    end
  end
end
