#!/usr/bin/env crystal

# community.general.mail module - sends an email over SMTP from wherever
# the module executes (roles almost always delegate it to localhost; a
# non-delegated run uploads and executes this same binary on the target).
# Unimplemented until 0.9.1627: deekayen.log_mailer round 5460362's
# "Send e-mail, attaching files." task was an unavailable-module skip
# where real ran the module and failed on the SMTP round trip.
#
# Real module = community.general's mail.py (GPL-3.0+, same license
# family - see NOTICE): a ~120-line main() over Python's smtplib + the
# email.mime builders. This plugin reproduces its observed semantics:
#
# - Connect flow: secure != "never" first tries SMTP_SSL (any failure
#   swallowed unless secure == "always", which fails with "Unable to
#   start an encrypted session to host:port: ..."); mail.py then calls
#   smtp.connect() a SECOND time on the live SSL handle, so a
#   successful always-SSL session opens TWO connections - reproduced.
#   Fallback is a plain SMTP connect whose OSError (connection refused,
#   DNS failure, timeout) is NOT caught by mail.py's
#   `except smtplib.SMTPException` - the exception propagates out of
#   the module and Ansible's generic crash path reports the bare
#   exception text ("[Errno 111] Connection refused"), so this plugin
#   fails with exactly that text too (live-probed against
#   ansible-playbook 2.19.11 on 127.0.0.1:1).
# - EHLO (no HELO fallback - mail.py never issues one), then for
#   secure in (starttls, try): STARTTLS when advertised (an explicit
#   starttls without the extension fails "StartTLS is not offered on
#   server host:port"), certificate verification OFF (smtplib uses a
#   non-verifying context), EHLO re-issued after the upgrade.
# - Optional AUTH (only when BOTH username and password are non-empty -
#   Python truthiness - and the server advertises AUTH): smtplib's
#   login preference order CRAM-MD5, PLAIN, LOGIN. A 4xx/5xx reply is
#   the "Authentication to host:port failed, please check your username
#   and/or password" failure; an AUTH-capable server with no usable
#   mechanism is "No Suitable authentication method was found on
#   host:port"; no AUTH extension at all is "No Authentication on the
#   server at host:port".
# - Message: MIMEMultipart("mixed") with From (parseaddr'd +
#   formataddr'd), Date (RFC 2822 local time), Subject (raw when ASCII,
#   RFC 2047 =?utf-8?b?...?= when not), Message-ID (make_msgid shape,
#   message_id_domain), the headers: list ("Key=value", "|" splits into
#   several, an unparseable one warns "Skipping header '...', unable to
#   parse"), X-Mailer "Ansible mail module" unless a custom header
#   already supplied one, To/Cc (bcc stays envelope-only), the
#   preamble, a text/<subtype> body part ("body\n\n", body defaults to
#   subject) and one application/octet-stream base64 part per attach:
#   file ("can't attach file ..." failure on a read error). The
#   multipart boundary is random, so byte-identical wire parity is
#   impossible by construction - only the SMTP conversation and the
#   header set matter.
# - sendmail: envelope sender = parseaddr(sender)'s address-only part;
#   recipients = the deduplicated to+cc+bcc address-only parts. MAIL
#   FROM refusal -> SMTPSenderRefused's str shape "(code, b'text',
#   'sender')"; an all-refused RCPT round is SMTPRecipientsRefused's
#   dict-repr shape (Python's len(refused) == len(recipients) check
#   includes the degenerate empty-recipient case); a non-250 DATA reply
#   is SMTPDataError's "code: b'text'" shape - all wrapped in mail.py's
#   "Failed to send mail to '<joined addrs>': ..." (the exact failure
#   deekayen.log_mailer hit live: (530, b'Authentication required',
#   'awx@tower.example.com')).
# - Per-recipient partial refusals are NOT a failure: mail.py exits
#   successfully with msg "Failed to send mail to at least one
#   recipient", a per-recipient "result" dict and one warning per
#   refused address. Fully delivered: msg "Mail sent successfully",
#   result {}. changed is false on every exit - the module never
#   reports a change.
# - check mode: the module declares check_mode support "none", so real
#   skips it ("remote module (...) does not support check mode") - same
#   skip shape tempfile.cr reproduces.

require "json"
require "openssl"
require "socket"
require "../src/krikri/base_plugin"

module Krikri
  class MailPlugin < BasePlugin
    # Every mail.py failure path goes through module.fail_json - these
    # carry the already-formatted user-facing message.
    class MailFailure < Exception; end

    # smtplib exception family. smtp_str reproduces Python's __str__ for
    # the classes mail.py's own handlers (or the uncaught-crash path)
    # actually print: SMTPResponseException is "code: b'text'" (the
    # stored reply text is bytes, so str() shows the b'' repr),
    # SMTPSenderRefused adds the sender tuple, SMTPRecipientsRefused is
    # the refused-dict repr.
    private module SMTPErrorFormat
      abstract def smtp_str : String
    end

    class SMTPResponseError < Exception
      include SMTPErrorFormat
      getter code : Int32
      getter reply : String

      def initialize(@code, @reply)
        super(nil)
      end

      def smtp_str : String
        "#{code}: b'#{reply}'"
      end
    end

    class SMTPSenderRefused < SMTPResponseError
      getter sender : String

      def initialize(code, reply, @sender)
        super(code, reply)
      end

      def smtp_str : String
        "(#{code}, b'#{reply}', '#{sender}')"
      end
    end

    class SMTPRecipientsRefused < Exception
      include SMTPErrorFormat
      getter refused : Hash(String, Tuple(Int32, String))

      def initialize(@refused)
        super(nil)
      end

      def smtp_str : String
        "{" + refused.map { |addr, pair| "'#{addr}': (#{pair[0]}, b'#{pair[1]}')" }.join(", ") + "}"
      end
    end

    # smtplib's getreply raises this on a dead/EOF connection; mail.py's
    # SMTPException handlers print its plain message.
    class SMTPServerDisconnected < Exception; end

    # mail.py's argument_spec aliases, for the plugin's own alias lookup
    # (the argspec validator handles the validation side; the module
    # body still reads its canonical names - same split find.cr does for
    # paths/path/name).
    ALIAS_FOR = {"sender" => "from", "to" => "recipients", "subject" => "msg"}

    @warnings = [] of String

    def execute : PluginResult
      if true?(@params["_ansible_check_mode"]?)
        invoked = @params["_module_name"]? || "community.general.mail"
        return PluginResult.new(changed: false, failed: false,
          msg: "remote module (#{invoked}) does not support check mode", skipped: true)
      end

      begin
        run_module
      rescue ex : MailFailure
        result = PluginResult.new(changed: false, failed: true, msg: ex.message.to_s)
        # fail_json(rc=1) - real's failure dict carries rc.
        result.extra["rc"] = JSON::Any.new(1_i64)
        attach_warnings(result)
        result
      end
    end

    # Python truthiness on the username/password pair: an empty string
    # is no auth, same as nil.
    private def smtp_auth_pair : Tuple(String, String)?
      username = @params["username"]?
      password = @params["password"]?
      if username && password && !username.empty? && !password.empty?
        {username, password}
      end
    end

    # The connect phase: SMTP_SSL's init connects and reads the
    # greeting, then mail.py's explicit smtp.connect() call closes and
    # reopens the TLS socket for a second greeting - two connections
    # when always-SSL succeeds. Any SSL-attempt failure is swallowed
    # (mail.py's `except Exception: pass`) unless secure == "always";
    # the fallback plain connect surfaces OSError text verbatim because
    # mail.py's `except smtplib.SMTPException` does not catch it.
    private def establish_session(secure : String, host : String, port : Int32, timeout : Int32,
                                  local_hostname : String) : Tuple(SMTPSession, Bool, Int32)
      if secure != "never"
        begin
          first = SMTPSession.new(host, port, timeout, local_hostname)
          first.connect_tls
          second = SMTPSession.new(host, port, timeout, local_hostname)
          second.connect_tls
          return {second, true, second.greeting_code}
        rescue ex : OpenSSL::SSL::Error
          fail("Unable to start an encrypted session to #{host}:#{port}: #{ex}") if secure == "always"
        rescue Exception
        end
      end

      smtp = SMTPSession.new(host, port, timeout, local_hostname)
      begin
        smtp.connect
      rescue ex : SMTPServerDisconnected
        fail("Unable to Connect #{host}:#{port}: #{ex.message}")
      rescue ex : Exception
        fail(python_os_error_text(ex))
      end
      {smtp, false, smtp.greeting_code}
    end

    private def run_module : PluginResult # ameba:disable Metrics/CyclomaticComplexity
      host = @params["host"]? || "localhost"
      port = (@params["port"]?.try(&.to_i32?)) || 25
      sender_param = @params["sender"]? || @params["from"]? || "root"
      subject = @params["subject"]? || @params["msg"]?
      unless subject
        # AnsibleModule's required check rejects the run before main()
        # - the argspec validator already surfaces real's wording; this
        # guard only keeps a bare-binary invocation honest.
        fail("missing required arguments: subject")
      end
      body = @params["body"]?
      body = subject if !body || body.empty?
      charset = @params["charset"]? || "utf-8"
      subtype = @params["subtype"]? || "plain"
      secure = @params["secure"]? || "try"
      timeout = (@params["timeout"]?.try(&.to_i32?)) || 20
      local_hostname = @params["ehlohost"]? || System.hostname
      message_id_domain = @params["message_id_domain"]? || "ansible"
      sender_phrase, sender_addr = parseaddr(sender_param)
      attach_files = parse_list("attach", [] of String)
      header_list = parse_list("headers", [] of String)
      recipients = parse_list("to", ["root"])
      copies = parse_list("cc", [] of String)
      blindcopies = parse_list("bcc", [] of String)

      smtp, secure_state, code = establish_session(secure, host, port, timeout, local_hostname)

      begin
        smtp.ehlo
      rescue ex : SMTPServerDisconnected
        fail("Helo failed for host #{host}:#{port}: #{ex.message}")
      end

      if code > 0 && !secure_state && (secure == "starttls" || secure == "try")
        if smtp.has_extn?("STARTTLS")
          begin
            smtp.starttls
          rescue ex : SMTPResponseError
            fail("Unable to start an encrypted session to #{host}:#{port}: #{ex.smtp_str}")
          rescue ex : SMTPServerDisconnected
            fail("Unable to start an encrypted session to #{host}:#{port}: #{ex.message}")
          rescue ex : OpenSSL::SSL::Error
            fail("Unable to start an encrypted session to #{host}:#{port}: #{ex}")
          end
          begin
            smtp.ehlo
          rescue ex : SMTPServerDisconnected
            fail("Helo failed for host #{host}:#{port}: #{ex.message}")
          end
        elsif secure == "starttls"
          fail("StartTLS is not offered on server #{host}:#{port}")
        end
      end

      # Python truthiness: an empty username/password is no auth.
      if (auth_pair = smtp_auth_pair)
        if smtp.has_extn?("AUTH")
          begin
            smtp.login(auth_pair[0], auth_pair[1])
          rescue SMTPResponseError
            fail("Authentication to #{host}:#{port} failed, please check your username and/or password")
          rescue SMTPServerDisconnected
            fail("No Suitable authentication method was found on #{host}:#{port}")
          end
        else
          fail("No Authentication on the server at #{host}:#{port}")
        end
      end
      @warnings << "Username and Password was sent without encryption" if !secure_state && smtp_auth_pair

      composed = compose_message(sender_phrase, sender_addr, subject, body, charset,
        subtype, header_list, recipients, copies, message_id_domain, attach_files)

      envelope_recipients = dedupe((blindcopies + recipients + copies).map { |a| parseaddr(a.strip)[1] })
      result = {} of String => Tuple(Int32, String)
      begin
        result = smtp.sendmail(sender_addr, envelope_recipients, composed)
      rescue ex : SMTPErrorFormat
        fail("Failed to send mail to '#{envelope_recipients.join(", ")}': #{ex.smtp_str}")
      rescue ex : SMTPServerDisconnected
        fail("Failed to send mail to '#{envelope_recipients.join(", ")}': #{ex.message}")
      end
      smtp.quit

      if result.empty?
        # Real's registered result carries failed: false explicitly
        # (live-verified: exit_json still backfills failed on this
        # module's success dict - the failed_flag mechanism in
        # PluginResult#to_json).
        success = PluginResult.new(changed: false, failed: false, msg: "Mail sent successfully",
          key_order: %w[msg result], failed_flag: true)
        success.extra["result"] = JSON::Any.new({} of String => JSON::Any)
        attach_warnings(success)
        success
      else
        result.each { |key, pair| @warnings << "Failed to send mail to '#{key}': #{pair[0]} b'#{pair[1]}'" }
        partial = PluginResult.new(changed: false, failed: false,
          msg: "Failed to send mail to at least one recipient", key_order: %w[msg result], failed_flag: true)
        partial.extra["result"] = JSON::Any.new(result.map do |addr, pair|
          {addr, JSON::Any.new([JSON::Any.new(pair[0].to_i64), JSON::Any.new("b'#{pair[1]}'")] of JSON::Any)}
        end.to_h)
        attach_warnings(partial)
        partial
      end
    end

    private def attach_warnings(result : PluginResult) : Nil
      result.extra["warnings"] = JSON::Any.new(@warnings.map { |warning| JSON::Any.new(warning) }) unless @warnings.empty?
    end

    private def fail(msg : String) : NoReturn
      raise MailFailure.new(msg)
    end

    # Wire params are strings; list params (to/cc/bcc/attach/headers)
    # ride comma-joined with the parser's non-string member markers -
    # the same defensive re-parse find.cr/apt.cr document (a whole-value
    # {{ list_var }} arrives as the JSON the wire serialized).
    private def parse_list(key : String, default : Array(String)) : Array(String)
      alias_key = ALIAS_FOR[key]?
      raw = @params[key]? || (alias_key ? @params[alias_key]? : nil)
      return default unless raw
      marked = non_string_member_list(key)
      return marked.compact_map(&.as_s?) if marked

      trimmed = raw.strip
      if trimmed.starts_with?('[') && trimmed.ends_with?(']')
        parsed = begin
          Array(String).from_json(trimmed)
        rescue
          nil
        end
        return parsed if parsed
      end
      trimmed.split(",").map(&.strip)
    end

    # Dedupe preserving first-seen order - Python's set() has
    # hash-randomized iteration order, so any stable order is as
    # faithful as the original.
    private def dedupe(list : Array(String)) : Array(String)
      seen = Set(String).new
      list.select { |item| seen.add?(item) }
    end

    # Python's str(OSError): "[Errno 111] Connection refused" - errno
    # value plus strerror. DNS resolution failure carries an EAI_* code
    # (negative in Python), which Crystal does not surface as Errno:
    # map the common text, pass anything else through.
    private def python_os_error_text(ex : Exception, path : String? = nil) : String
      msg = ex.message.to_s
      return "[Errno -2] Name or service not known" if msg.includes?("Name or service not known")
      return "timed out" if ex.is_a?(IO::TimeoutError)
      if ex.responds_to?(:os_error) && (errno = ex.os_error)
        "[Errno #{errno.value}] #{strerror(errno.value.to_i)}#{path ? ": '#{path}'" : ""}"
      else
        msg
      end
    end

    private def strerror(value : Int32) : String
      String.new(LibC.strerror(value))
    end

    # Python's email.utils.parseaddr, restricted to the shapes roles
    # actually write: bare addresses, "Phrase <addr>" (phrase may be
    # quoted) and "addr (Comment)" (the community.general docs' own
    # example). No RFC 5322 comment/quoted-pair grammar beyond that.
    private def parseaddr(value : String) : Tuple(String, String)
      s = value.strip
      lt = s.index('<')
      gt = s.rindex('>')
      if lt && gt && gt > lt
        addr = s[(lt + 1)...gt].strip
        phrase = s[0...lt].strip.gsub(/^"(.*)"$/, "\\1")
        return {phrase, addr}
      end
      if comment = s.match(/\(([^()]*)\)/)
        rest = s.gsub(/\([^()]*\)/, "").strip
        return {comment[1].strip, rest}
      end
      {"", s}
    end

    # Python's email.utils.formataddr: quote the phrase only when it
    # contains RFC specials, escaping " and \.
    private def formataddr(phrase : String, addr : String) : String
      return addr if phrase.empty?
      if phrase.matches?(/[\\()<>@\[\]:;,."]/)
        quoted = phrase.gsub(/(["\\])/) { "\\#{$1}" }
        "\"#{quoted}\" <#{addr}>"
      else
        "#{phrase} <#{addr}>"
      end
    end

    # Python's email.utils.formatdate(localtime=True): RFC 2822 with a
    # numeric +-HHMM zone (no colon).
    private def formatdate_local : String
      t = Time.local
      days = %w[Sun Mon Tue Wed Thu Fri Sat]
      months = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
      offset = t.offset
      sign = offset >= 0 ? "+" : "-"
      magnitude = offset.abs
      zone = "#{sign}#{(magnitude // 3600).to_s.rjust(2, '0')}#{((magnitude % 3600) // 60).to_s.rjust(2, '0')}"
      "#{days[t.day_of_week.value % 7]}, #{t.day.to_s.rjust(2, '0')} #{months[t.month - 1]} #{t.year} " \
      "#{t.hour.to_s.rjust(2, '0')}:#{t.minute.to_s.rjust(2, '0')}:#{t.second.to_s.rjust(2, '0')} #{zone}"
    end

    # The SUBJECT is stored as a live Header OBJECT and only encoded at
    # as_string() time: the us-ascii charset stays raw ASCII (the role
    # corpus's charset: us-ascii case - live verified), while a non-ascii
    # charset like the utf-8 default encodes the WHOLE value even when it
    # is pure ASCII (live-verified: utf-8 subject went out QP-encoded
    # with space->underscore).
    private def encode_subject(value : String, charset : String) : String
      name = charset.downcase
      if name.in?("us-ascii", "ascii")
        return value
      end
      qp_header_encode(value, name)
    end

    # CUSTOM headers: mail.py converts the value to a plain STRING at
    # module time (to_native(Header(h_val, charset))) - an ASCII value
    # stays raw even under the utf-8 default (live-verified: "Reply-To:
    # john@example.com" crossed the wire raw); a non-ASCII value becomes
    # a QP encoded word (Header's own __str__).
    private def encode_custom_header(value : String, charset : String) : String
      return value if value.ascii_only?
      qp_header_encode(value, charset.downcase)
    end

    # Python's email.header QP word encoding: space becomes '_', the
    # RFC 2047 header-safe set (alnum + "!*+-/") stays raw, everything
    # else becomes =XX (no folding; folding only matters for
    # header-length pedantry).
    private def qp_header_encode(value : String, name : String) : String
      encoded = value.each_char.map do |char|
        if char == ' '
          "_"
        elsif char.alphanumeric? || "!*+-/".includes?(char)
          char.to_s
        else
          "=#{char.ord.to_s(16).upcase.rjust(2, '0')}"
        end
      end.join
      "=?#{name}?q?#{encoded}?="
    end

    # MIMEMultipart("mixed")'s own serialization: its Content-Type and
    # MIME-Version headers come FIRST (set at Message init), then the
    # module's headers in insertion order, then the preamble line, then
    # the text part and the attachment parts.
    private def compose_message(sender_phrase : String, sender_addr : String, subject : String, body : String,
                                charset : String, subtype : String, header_list : Array(String),
                                recipients : Array(String), copies : Array(String),
                                message_id_domain : String, attach_files : Array(String)) : String
      boundary = "===============#{Random.new.rand(922_337_203_685_477_5807).to_s.rjust(19, '0')}=="
      headers = [] of Tuple(String, String)
      headers << {"From", formataddr(sender_phrase, sender_addr)}
      headers << {"Date", formatdate_local}
      headers << {"Subject", encode_subject(subject, charset)}
      # make_msgid's shape: centisecond timestamp, pid, big random -
      # all unpredictable by construction, only the shape is stable.
      headers << {"Message-ID", "<#{Time.utc.to_unix_ms // 10}.#{Process.pid}.#{Random.new.rand(922_337_203_685_477_5807)}@#{message_id_domain}>"}

      custom_keys = Set(String).new
      header_list.each do |entry|
        entry.split("|").each do |hdr|
          hdr = hdr.strip
          key, value = hdr.split("=", 2)
          headers << {key, encode_custom_header(value, charset)}
          custom_keys << key.downcase
        rescue
          @warnings << "Skipping header '#{hdr}', unable to parse"
        end
      end
      headers << {"X-Mailer", "Ansible mail module"} unless custom_keys.includes?("x-mailer")

      to_list = recipients.map { |addr| parseaddr(addr.strip) }
      headers << {"To", to_list.map { |pair| formataddr(pair[0], pair[1]) }.join(", ")}
      cc_list = copies.map { |addr| parseaddr(addr.strip) }
      headers << {"Cc", cc_list.map { |pair| formataddr(pair[0], pair[1]) }.join(", ")}

      io = IO::Memory.new
      # MIMEMultipart(_charset=...)'s own Content-Type - the email lib
      # renders the private _charset kwarg as a literal "-charset"
      # attribute (verified: MIMEMultipart(_charset='utf-8')
      # ['Content-Type'] == 'multipart/mixed; -charset="utf-8"').
      io << "Content-Type: multipart/mixed; -charset=\"#{charset}\"; boundary=\"#{boundary}\"\n"
      io << "MIME-Version: 1.0\n"
      headers.each do |pair|
        io << pair[0] << ": " << pair[1] << "\n"
      end
      io << "\n"
      # Multipart message's preamble rides straight into the first
      # boundary (no blank line - live-verified wire transcript).
      io << "Multipart message\n"

      io << "--#{boundary}\n"
      text_payload = "#{body}\n\n"
      # Charset decides, not content: MIMEText's utf-8 body is BASE64
      # even when the text is pure ASCII (live-verified), us-ascii is
      # 7bit, any other charset rides 8bit raw.
      if charset.downcase.in?("us-ascii", "ascii")
        cte = "7bit"
      elsif charset.downcase.in?("utf-8", "utf8")
        cte = "base64"
      else
        cte = "8bit"
      end
      io << "Content-Type: text/#{subtype}; charset=\"#{charset}\"\n"
      io << "MIME-Version: 1.0\n"
      io << "Content-Transfer-Encoding: #{cte}\n"
      io << "\n"
      io << (cte == "base64" ? b64_76(text_payload) : text_payload)

      attach_files.each do |filename|
        content = begin
          File.read(filename)
        rescue ex : Exception
          # Python's open() errors carry the filename in their str().
          fail("Failed to send community.general.mail: can't attach file #{filename}: " \
               "#{python_os_error_text(ex, path: filename)}")
        end
        # compat32's Generator prefixes every boundary after the first
        # with a newline (live-verified: a blank line precedes each
        # subsequent boundary in real's wire transcript).
        io << "\n--#{boundary}\n"
        io << "Content-Type: application/octet-stream\n"
        io << "MIME-Version: 1.0\n"
        io << "Content-Transfer-Encoding: base64\n"
        io << "Content-disposition: attachment; filename=\"#{File.basename(filename)}\"\n"
        io << "\n"
        io << b64_76(content)
      end
      io << "\n--#{boundary}--\n"
      io.to_s
    end

    # Python's base64.encodestring: 76-char lines, each newline-
    # terminated (email.encoders.encode_base64's own encoder).
    private def b64_76(payload : String) : String
      encoded = Base64.strict_encode(payload)
      return "" if encoded.empty?
      encoded.scan(/.{1,76}/).map(&.[0]).join("\n") + "\n"
    end

    # Minimal smtplib SMTP client. One session owns one socket; every
    # server reply is (code, text) with multi-line continuations joined
    # by "\n" exactly as smtplib's getreply hands them to callers.
    private class SMTPSession
      getter greeting_code : Int32 = 0
      getter capabilities = Hash(String, String).new

      @io : IO?
      @raw_tcp : ::Socket?

      def initialize(@host : String, @port : Int32, @timeout : Int32, @local_hostname : String)
      end

      def has_extn?(name : String) : Bool
        capabilities.has_key?(name.upcase)
      end

      def connect : Nil
        tcp = open_tcp
        arm_timeouts(tcp)
        @raw_tcp = tcp
        @io = tcp
        read_greeting
      end

      # TLS-immediately handshake (SMTP_SSL). Certificate verification
      # is OFF: smtplib's default context does not verify.
      def connect_tls : Nil
        tcp = open_tcp
        arm_timeouts(tcp)
        @raw_tcp = tcp
        context = OpenSSL::SSL::Context::Client.new
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        @io = OpenSSL::SSL::Socket::Client.new(tcp, context, sync_close: true)
        read_greeting
      end

      def starttls : Nil
        code, reply = command("starttls")
        raise SMTPResponseError.new(code, reply) if code != 220
        capabilities.clear
        tcp = raw_socket
        context = OpenSSL::SSL::Context::Client.new
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        @io = OpenSSL::SSL::Socket::Client.new(tcp, context, sync_close: true)
      end

      # Both sockets are armed before any command runs; a nil here is
      # the dead-session case smtplib reports as a disconnect.
      private def raw_socket : ::Socket
        @raw_tcp || raise SMTPServerDisconnected.new("Connection unexpectedly closed")
      end

      private def live_io : IO
        @io || raise SMTPServerDisconnected.new("Connection unexpectedly closed")
      end

      def ehlo : Nil
        code, reply = command("ehlo #{@local_hostname}")
        capabilities.clear
        if code == 250
          reply.split("\n").each do |line|
            line = line.strip
            next if line.empty?
            key = line.split[0].upcase
            capabilities[key] = line[key.size..].strip
          end
        end
      end

      # smtplib.login's preference order: CRAM-MD5, PLAIN, LOGIN.
      def login(username : String, password : String) : Nil
        mechanisms = capabilities["AUTH"]?.try(&.split) || [] of String
        ["CRAM-MD5", "PLAIN", "LOGIN"].each do |mechanism|
          next unless mechanisms.map(&.upcase).includes?(mechanism)
          case mechanism
          when "CRAM-MD5"
            code, reply = command("AUTH CRAM-MD5")            raise SMTPResponseError.new(code, reply) if code != 334
            challenge = Base64.decode_string(reply)
            digest = OpenSSL::HMAC.hexdigest(:md5, password, challenge)
            code, reply = command(Base64.strict_encode("#{username} #{digest}"))
            raise SMTPResponseError.new(code, reply) unless code == 235
            return
          when "PLAIN"
            code, reply = command("AUTH PLAIN #{Base64.strict_encode("\x00#{username}\x00#{password}")}")
            raise SMTPResponseError.new(code, reply) unless code == 235
            return
          when "LOGIN"
            code, reply = command("AUTH LOGIN")
            raise SMTPResponseError.new(code, reply) if code != 334
            code, reply = command(Base64.strict_encode(username))
            raise SMTPResponseError.new(code, reply) if code != 334
            code, reply = command(Base64.strict_encode(password))
            raise SMTPResponseError.new(code, reply) unless code == 235
            return
          end
        end
        raise SMTPServerDisconnected.new("No suitable authentication method found")
      end

      # smtplib.sendmail: envelope sender, per-recipient refusals, DATA
      # with dot-stuffing. Returns the partially-refused dict (empty on
      # full success). Python's all-refused check
      # (len(refused) == len(recipients)) includes the degenerate
      # empty-recipient case.
      def sendmail(sender : String, recipients : Array(String), message : String) : Hash(String, Tuple(Int32, String))
        mail_cmd = "mail from:<#{sender}>"
        # smtplib.sendmail appends size= (the composed message's byte
        # length) when the server advertises SIZE (live-verified in the
        # fake-SMTP transcript).
        mail_cmd += " size=#{message.bytesize}" if has_extn?("SIZE")
        code, reply = command(mail_cmd)
        raise SMTPSenderRefused.new(code, reply, sender) if code != 250

        senderrs = {} of String => Tuple(Int32, String)
        recipients.each do |addr|
          code, reply = command("rcpt to:<#{addr}>")
          senderrs[addr] = {code, reply} if code != 250 && code != 251
        end
        raise SMTPRecipientsRefused.new(senderrs) if senderrs.size == recipients.size

        code, reply = command("data")
        raise SMTPResponseError.new(code, reply) if code != 354
        write_data(message)
        code, reply = getreply
        raise SMTPResponseError.new(code, reply) if code != 250
        senderrs
      end

      def quit : Nil
        command("quit")
      rescue
        nil
      end

      # Some sandboxes/seccomp filters return EAGAIN/EINPROGRESS as the
      # FINAL verdict of a non-blocking connect(2), which never happens
      # on an unsandboxed Linux (EINPROGRESS there is transient and the
      # event loop consumes it by reading SO_ERROR). Python's blocking
      # connect sees the true errno, so re-probe with a raw blocking
      # connect to recover it (or connect successfully) - without this
      # the plugin reports "[Errno 115] Operation now in progress" where
      # real reports "[Errno 111] Connection refused".
      private def open_tcp : ::Socket
        TCPSocket.new(@host, @port, dns_timeout: @timeout, connect_timeout: @timeout)
      rescue ex : Socket::ConnectError
        blocking_reprobe(ex)
      end

      private def blocking_reprobe(original : Exception) : ::Socket
        ::Socket::Addrinfo.tcp(@host, @port).each do |addrinfo|
          sock = ::Socket.new(addrinfo.family, addrinfo.type, addrinfo.protocol, blocking: true)
          begin
            sock.connect(addrinfo)
            return sock
          rescue ex : Socket::ConnectError
            sock.close
            raise ex
          rescue
            sock.close
            raise original
          end
        end
        raise original
      end

      private def arm_timeouts(sock : ::Socket) : Nil
        sock.read_timeout = @timeout
        sock.write_timeout = @timeout
        sock.sync = true
      end

      private def command(text : String) : Tuple(Int32, String)
        io = live_io
        io << text << "\r\n"
        io.flush
        getreply
      rescue ex : SMTPServerDisconnected
        raise ex
      rescue IO::Error
        raise SMTPServerDisconnected.new("Connection unexpectedly closed")
      end

      # dot-stuffing + CRLF translation, smtplib's _fix_eols /
      # _quote_periods: a terminator "." is appended after the last
      # line's own newline when the message ends with one, or after an
      # added CRLF when it does not.
      private def write_data(message : String) : Nil
        normalized = message.gsub("\r\n", "\n").gsub('\r', "\n").gsub('\n', "\r\n")
        stuffed = normalized.split("\r\n").map { |line| line.starts_with?(".") ? ".#{line}" : line }.join("\r\n")
        terminator = stuffed.ends_with?("\n") ? ".\r\n" : "\r\n.\r\n"
        io = live_io
        io << stuffed << terminator
        io.flush
      rescue IO::Error
        raise SMTPServerDisconnected.new("Connection unexpectedly closed")
      end

      private def read_greeting : Nil
        code, _ = getreply
        @greeting_code = code
      rescue ex : SMTPServerDisconnected
        raise ex
      rescue IO::Error | OpenSSL::SSL::Error
        raise SMTPServerDisconnected.new("Connection unexpectedly closed")
      end

      private def getreply : Tuple(Int32, String)
        io = live_io
        code = 0
        lines = [] of String
        loop do
          line = io.gets("\r\n") || raise SMTPServerDisconnected.new("Connection unexpectedly closed")
          line = line.chomp("\r\n")
          if line.size >= 3 && (parsed = line[0, 3].to_i32?)
            code = parsed
            # smtplib's getreply strips the code, the continuation dash
            # and surrounding whitespace from each line (live-verified:
            # real's ehlo reply text has no leading dashes).
            lines << (line.size > 3 ? line[3..].lstrip("- \t") : "")
            break unless line[3]? == '-'
          else
            raise SMTPServerDisconnected.new("Connection unexpectedly closed")
          end
        end
        {code, lines.join("\n")}
      rescue ex : SMTPServerDisconnected
        raise ex
      rescue IO::Error
        raise SMTPServerDisconnected.new("Connection unexpectedly closed")
      end
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::MailPlugin.new(config)
plugin.run
