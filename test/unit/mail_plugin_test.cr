require "../minitest_helper"
require "socket"
require "json"

# Regression for round 5460362 (deekayen.log_mailer): the role's
# "Send e-mail, attaching files." task was an unavailable-module skip
# where real ran community.general.mail and failed on the SMTP round
# trip. The plugin reproduces smtplib's SMTP conversation and the
# module's failure wordings - the wire shape was diffed against a live
# ansible-playbook 2.19.11 run over a fake SMTP server (the sender-
# refused wording below is byte-identical to real's).
private class FakeSMTP
  getter port : Int32
  getter transcript = [] of String
  getter data_parts = [] of String

  def initialize(@mode : String)
    @listener = TCPServer.new("127.0.0.1", 0)
    @port = @listener.local_address.port
  end

  def start : Nil
    spawn do
      loop do
        conn = @listener.accept
        conn.sync = true
        conn.read_timeout = 5.seconds
        spawn handle(conn)
      end
    rescue
      nil
    end
  end

  private def handle(conn : TCPSocket) : Nil # ameba:disable Metrics/CyclomaticComplexity
    conn << "220 fake ESMTP ready\r\n"
    data_mode = false
    data = IO::Memory.new
    while (line = conn.gets("\r\n"))
      @transcript << line.chomp("\r\n")
      if data_mode
        if line.chomp("\r\n") == "."
          data_mode = false
          conn << "250 OK queued\r\n"
        else
          data << line << "\n"
        end
        next
      end
      upper = line.upcase
      if upper.starts_with?("EHLO") || upper.starts_with?("HELO")
        auth_line = @mode.in?("auth-ok", "auth-fail") ? "250-AUTH PLAIN LOGIN\r\n" : ""
        conn << "250-fake greets you\r\n#{auth_line}250 SIZE 10485760\r\n"
      elsif upper.starts_with?("MAIL FROM")
        if @mode == "refuse"
          conn << "530 Authentication required\r\n"
          break
        end
        conn << "250 OK\r\n"
      elsif upper.starts_with?("AUTH PLAIN") || upper.starts_with?("AUTH LOGIN") || upper.starts_with?("AUTH CRAM")
        if @mode == "auth-fail"
          conn << "535 5.7.8 Error: authentication failed\r\n"
          break
        end
        conn << "235 2.7.0 Accepted\r\n"
      elsif upper.starts_with?("RCPT TO")
        conn << "250 OK\r\n"
      elsif upper.starts_with?("DATA")
        conn << "354 go ahead\r\n"
        data_mode = true
      elsif upper.starts_with?("QUIT")
        conn << "221 bye\r\n"
        break
      else
        conn << "500 unrecognized\r\n"
      end
    end
    @data_parts << data.to_s
  rescue
  ensure
    begin
      conn.close
    rescue
      nil
    end
  end
end

private def run_mail(params : Hash(String, String)) : JSON::Any
  PluginSpecHelper.run("mail", params)
end

describe "community.general.mail plugin" do
  it "delivers a plain message over a fake SMTP server" do
    server = FakeSMTP.new("ok")
    server.start
    dir = PluginSpecHelper.tmp_path("mail-deliver")
    Dir.mkdir_p(dir)
    attach = File.join(dir, "testhost_logs.tar.bz2")
    File.write(attach, "fake archive\n")

    result = run_mail({
      "host"    => "127.0.0.1",
      "port"    => server.port.to_s,
      "secure"  => "never",
      "subject" => "[Ansible] Logs from testhost",
      "body"    => "Attached are logs from /var/log on testhost.fqdn.",
      "from"    => "awx@tower.example.com",
      "to"      => "log_team@example.com",
      "attach"  => attach,
    })

    (result["failed"]?.nil? || result["failed"].as_bool == false).must_equal(true)
    result["msg"].as_s.must_equal("Mail sent successfully")
    result["result"].as_h.must_equal({} of String => JSON::Any)

    transcript = server.transcript.join("\n")
    transcript.must_include("mail from:<awx@tower.example.com>")
    transcript.must_include("rcpt to:<log_team@example.com>")
    transcript.must_include("data")
    transcript.must_include("quit")
    # utf-8 charset QP-encodes the whole subject (spaces become
    # underscores) even when pure ASCII - live-verified against real's
    # wire transcript.
    transcript.must_include("Subject: =?utf-8?q?=5BAnsible=5D_Logs_from_testhost?=")
    transcript.must_include("To: log_team@example.com")
    transcript.must_include("Cc: ")
    transcript.must_include("X-Mailer: Ansible mail module")
    transcript.must_include("Message-ID: <")
    transcript.must_include("@ansible>")
    transcript.must_include("Multipart message")
    # utf-8 charset's body rides base64 even when pure ASCII, and the
    # attachment is base64 with a quoted filename disposition - both
    # live-verified against real's wire transcript.
    payload = server.data_parts.join
    payload.must_include("Content-Type: multipart/mixed; -charset=\"utf-8\"; boundary=\"")
    payload.must_include("Content-Type: text/plain; charset=\"utf-8\"")
    payload.must_include("Content-Transfer-Encoding: base64")
    payload.must_include(Base64.strict_encode("Attached are logs from /var/log on testhost.fqdn.\n\n"))
    payload.must_include("Content-disposition: attachment; filename=\"testhost_logs.tar.bz2\"")
    payload.must_include(Base64.strict_encode("fake archive\n"))
  end

  it "falls back to a plaintext session under the default secure: try" do
    server = FakeSMTP.new("ok")
    server.start
    result = run_mail({
      "host"    => "127.0.0.1",
      "port"    => server.port.to_s,
      "subject" => "probe try",
      "from"    => "a@example.com",
      "to"      => "b@example.com",
    })
    (result["failed"]?.nil? || result["failed"].as_bool == false).must_equal(true)
    result["msg"].as_s.must_equal("Mail sent successfully")
    server.transcript.join("\n").must_include("mail from:<a@example.com>")
  end

  it "fails with the exact sender-refused wording the round hit" do
    server = FakeSMTP.new("refuse")
    server.start
    result = run_mail({
      "host"    => "127.0.0.1",
      "port"    => server.port.to_s,
      "secure"  => "never",
      "subject" => "probe",
      "from"    => "awx@tower.example.com",
      "to"      => "log_team@example.com",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Failed to send mail to 'log_team@example.com': " \
      "(530, b'Authentication required', 'awx@tower.example.com')")
    result["rc"].as_i.must_equal(1)
  end

  it "reports a refused connect like real's uncaught OSError text" do
    probe = TCPServer.new("127.0.0.1", 0)
    dead_port = probe.local_address.port
    probe.close

    result = run_mail({
      "host"    => "127.0.0.1",
      "port"    => dead_port.to_s,
      "secure"  => "never",
      "subject" => "probe",
      "to"      => "log_team@example.com",
    })
    result["failed"].as_bool.must_equal(true)
    # Real crashes the module with the bare Python OSError str
    # (mail.py's `except smtplib.SMTPException` does not catch it);
    # live-verified vs 2.19.11 on 127.0.0.1:1.
    result["msg"].as_s.must_equal("[Errno 111] Connection refused")
  end

  it "fails an auth rejection with the real wording" do
    server = FakeSMTP.new("auth-fail")
    server.start
    result = run_mail({
      "host"     => "127.0.0.1",
      "port"     => server.port.to_s,
      "secure"   => "never",
      "username" => "user@example.com",
      "password" => "hunter2",
      "subject"  => "probe",
      "to"       => "b@example.com",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Authentication to 127.0.0.1:#{server.port} failed, please check your username and/or password")
  end

  it "authenticates with AUTH PLAIN when the server advertises it" do
    server = FakeSMTP.new("auth-ok")
    server.start
    result = run_mail({
      "host"     => "127.0.0.1",
      "port"     => server.port.to_s,
      "secure"   => "never",
      "username" => "user@example.com",
      "password" => "hunter2",
      "subject"  => "probe",
      "to"       => "b@example.com",
    })
    (result["failed"]?.nil? || result["failed"].as_bool == false).must_equal(true)
    result["msg"].as_s.must_equal("Mail sent successfully")
    server.transcript.join("\n").must_include("AUTH PLAIN")
  end

  it "fails on a missing attachment with the real wording" do
    server = FakeSMTP.new("ok")
    server.start
    missing = File.join(PluginSpecHelper.tmp_path("mail-missing"), "nope.txt")
    result = run_mail({
      "host"    => "127.0.0.1",
      "port"    => server.port.to_s,
      "secure"  => "never",
      "subject" => "probe",
      "to"      => "b@example.com",
      "attach"  => missing,
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Failed to send community.general.mail: can't attach file #{missing}: " \
      "[Errno 2] No such file or directory: '#{missing}'")
  end

  it "skips in check mode like a module without check-mode support" do
    result = run_mail({
      "subject"             => "probe",
      "to"                  => "b@example.com",
      "host"                => "127.0.0.1",
      "port"                => "25",
      "_ansible_check_mode" => "True",
    })
    result["skipped"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("remote module (community.general.mail) does not support check mode")
  end

  it "keeps phrase/comment address shapes and parses headers" do
    server = FakeSMTP.new("ok")
    server.start
    result = run_mail({
      "host"    => "127.0.0.1",
      "port"    => server.port.to_s,
      "secure"  => "never",
      "subject" => "probe",
      "from"    => "Jane Jolie <jane@example.net>",
      "to"      => "John Doe <j.d@example.org>",
      "cc"      => "root@localhost (Charlie Root)",
      "headers" => "Reply-To=john@example.com|X-Broken header",
    })
    (result["failed"]?.nil? || result["failed"].as_bool == false).must_equal(true)
    transcript = server.transcript.join("\n")
    transcript.must_include("From: Jane Jolie <jane@example.net>")
    transcript.must_include("To: John Doe <j.d@example.org>")
    transcript.must_include("Cc: Charlie Root <root@localhost>")
    transcript.must_include("Reply-To: john@example.com")
    # The unparseable header warns - it rides the result's warnings key,
    # never the SMTP wire (live-verified vs 2.19.11: same wording, same
    # key).
    result["warnings"].as_a.map(&.as_s).must_equal(["Skipping header 'X-Broken header', unable to parse"])
  end
end
