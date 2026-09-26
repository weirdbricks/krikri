require "http/client"
require "uri"

module Krikri
  # Controller-side lookup plugin helpers shared by every template engine
  # (paths, config defaults, url/sequence/csvfile/ini/password lookups).
  # Plain String in, plain values out, so no engine's value type leaks in.
  module LookupPlugins
    private def self.default_colors : Hash(String, String)
      {
        "COLOR_OK"          => "green",
        "COLOR_CHANGED"     => "yellow",
        "COLOR_SKIP"        => "cyan",
        "COLOR_UNREACHABLE" => "bright red",
        "COLOR_ERROR"       => "red",
        "COLOR_FAILED"      => "red",
        "COLOR_DEBUG"       => "dark gray",
        "COLOR_VERBOSE"     => "blue",
        "COLOR_WARN"        => "bright purple",
      }
    end

    private def self.default_general : Hash(String, String)
      {
        "DEFAULT_BECOME_USER"   => "root",
        "DEFAULT_ROLES_PATH"    => "~/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles",
        "DEFAULT_HOST_LIST"     => "/etc/ansible/hosts",
        "RETRY_FILES_SAVE_PATH" => "",
        "DEFAULT_TIMEOUT"       => "10",
        "DEFAULT_FORKS"         => "5",
      }
    end

    def self.ansible_config_value(name : String) : String
      key = name.upcase
      (default_colors[key]? || default_general[key]?) || ENV["ANSIBLE_#{key}"]? || ""
    end

    def self.resolve_lookup_path(path : String, role_path : String?) : String
      return path if path.starts_with?('/')
      role_path ? File.join(role_path, "files", path) : path
    end

    # A relative first_found `paths:` entry can resolve against either
    # the role's own ROOT directory OR (buluma.confluence's own `paths:
    # ['../vars']` idiom, real Ansible resolves this relative to tasks/,
    # not role_path itself) its tasks/ subdirectory - same two-root
    # search ExpressionEvaluator's own #resolve_first_found_roots
    # applies (see that method's comment for the full story and the
    # round165 repro that found this gap independently on this,
    # separate, Crinja-backed evaluator).
    def self.resolve_first_found_roots(path : String, role_path : String?) : Array(String)
      return [path] if path.starts_with?('/')
      return [path] unless role_path

      [File.join(role_path, path), Path.new(role_path, "tasks", path).normalize.to_s]
    end

    # Mirrors ExpressionEvaluator's own #fetch_url_lines (redirect-
    # following GET, stripped/blank-rejected lines), returning a real
    # Array(String)? here instead of JSON array text - nil on any
    # failure (unreachable host, non-2xx, too many redirects).
    def self.fetch_url_lines(url : String, redirects_left : Int32 = 5) : Array(String)?
      return nil if redirects_left < 0

      response = HTTP::Client.get(url)

      if response.status.redirection? && (location = response.headers["Location"]?)
        resolved = URI.parse(location).absolute? ? location : URI.parse(url).resolve(location).to_s
        return fetch_url_lines(resolved, redirects_left - 1)
      end

      return nil unless response.success?

      response.body.lines.map(&.strip).reject(&.empty?)
    rescue
      nil
    end

    PASSWORD_CHARS  = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a + [".", ",", ":", "-", "_"]
    PASSWORD_LENGTH = 20

    # lookup('sequence', 'start=1 end=5 stride=1 format=web%02d') - same
    # logic as ExpressionEvaluator's own #evaluate_sequence_lookup,
    # returning a real Array(String) here instead of JSON array text.
    private def self.sequence_options(tokens : Array(String)) : Hash(String, String)
      opts = Hash(String, String).new
      if tokens[0]? && !tokens[0].includes?('=') && (range_match = tokens[0].match(/^(\d+)-(\d+)$/))
        opts["start"] = range_match[1]
        opts["end"] = range_match[2]
        tokens = tokens[1..]
      end
      tokens.each do |token|
        key, sep, val = token.partition('=')
        opts[key] = val unless sep.empty?
      end
      opts
    end

    def self.sequence_lookup(raw_arg : String) : Array(String)
      opts = sequence_options(raw_arg.strip.split(/\s+/))

      start = opts["start"]?.try(&.to_i) || 1
      stride = opts["stride"]?.try(&.to_i) || 1
      count = opts["count"]?.try(&.to_i)
      finish = opts["end"]?.try(&.to_i)
      format = opts["format"]?

      total = count || (finish ? ((finish - start) // stride) + 1 : 1)
      return [] of String if total < 0

      values = (0...total).map { |i| start + i * stride }
      format ? values.map { |v| (format % v) rescue v.to_s } : values.map(&.to_s)
    end

    # lookup('csvfile', 'key file=data.csv delimiter=, col=1') - same
    # logic as ExpressionEvaluator's own #evaluate_csvfile_lookup.
    def self.csvfile_lookup(raw_arg : String) : String?
      tokens = raw_arg.strip.split(/\s+/)
      key = tokens[0]?
      return nil unless key

      opts = Hash(String, String).new
      tokens[1..].each do |token|
        k, sep, v = token.partition('=')
        opts[k] = v unless sep.empty?
      end

      file = opts["file"]?
      return nil unless file
      delimiter = opts["delimiter"]? || ","
      col = opts["col"]?.try(&.to_i) || 1

      begin
        File.each_line(file) do |line|
          fields = line.split(delimiter)
          next unless fields[0]?.try(&.strip) == key
          return (fields[col]? || "").strip
        end
      rescue
      end
      nil
    end

    # lookup('ini', 'value section=section1 file=file.ini') - same logic
    # as ExpressionEvaluator's own #evaluate_ini_lookup.
    def self.ini_lookup(raw_arg : String) : String?
      tokens = raw_arg.strip.split(/\s+/)
      value_key = tokens[0]?
      return nil unless value_key

      opts = Hash(String, String).new
      tokens[1..].each do |token|
        k, sep, v = token.partition('=')
        opts[k] = v unless sep.empty?
      end

      file = opts["file"]?
      return nil unless file
      wanted_section = opts["section"]? || "DEFAULT"

      begin
        current_section = "DEFAULT"
        File.each_line(file) do |raw_line|
          line = raw_line.strip
          next if line.empty? || line.starts_with?(';') || line.starts_with?('#')
          if line.starts_with?('[') && line.ends_with?(']')
            current_section = line[1..-2]
            next
          end
          next unless current_section == wanted_section
          k, sep, v = line.partition('=')
          return v.strip if sep != "" && k.strip == value_key
        end
      rescue
      end
      nil
    end

    # lookup('password', 'path [length=N]') - generates a random
    # password ONCE and persists it to *path* (real Ansible's own
    # behavior: a later run/lookup reads the same file back rather than
    # generating a new value every time). Same logic as
    # ExpressionEvaluator's own #evaluate_password_lookup.
    def self.password_lookup(raw_arg : String, role_path : String?) : String
      tokens = raw_arg.strip.split(/\s+/)
      path = tokens[0]?
      return "" unless path
      resolved_path = resolve_lookup_path(path, role_path)

      length = PASSWORD_LENGTH
      tokens[1..].each do |token|
        length = token[7..].to_i? || length if token.starts_with?("length=")
      end

      # `/dev/null` means "fresh random password, don't persist it" -
      # real Ansible's own password lookup special-cases that exact path
      # for both the read-back and the write. See
      # ExpressionEvaluator#evaluate_password_lookup's own comment for
      # how the missing case was found (imntreal.smallstep_ca wrote
      # empty password files, and `step ca init` then prompted).
      return Array.new(length) { PASSWORD_CHARS.sample(Random::Secure) }.join if path == "/dev/null"

      return File.read(resolved_path).chomp if File.exists?(resolved_path)

      password = Array.new(length) { PASSWORD_CHARS.sample(Random::Secure) }.join
      begin
        dir = File.dirname(resolved_path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        # 0600, chmod before the bytes land - see the same fix in
        # ExpressionEvaluator#evaluate_password_lookup.
        File.open(resolved_path, "w") do |io|
          io.chmod(0o600)
          io.write((password + "\n").to_slice)
        end
      rescue
      end
      password
    end
  end
end
