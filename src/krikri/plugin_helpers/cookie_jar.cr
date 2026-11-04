require "http/client"
require "uri"

module Krikri
  module PluginHelpers
    # The slice of Python's http.cookiejar that Ansible's fetch_url puts to
    # work on every HTTP download: fetch_url ALWAYS attaches a cookie jar
    # and an HTTPCookieProcessor (urls.py's "if not isinstance(cookies,
    # cookiejar.CookieJar): cookies = cookiejar.CookieJar()"), so each
    # response's Set-Cookie headers feed one jar and every later request -
    # every redirect hop included, urllib re-runs the processor per
    # request - carries back the cookies that match it.
    #
    # Real-world impact (xilonz.trellis_nixstats, issue #868): an
    # SSO/login redirect chain that only converges once the flow's own
    # session/csrf cookies travel with the hops. A cookie-less client is
    # redirected forever (each hop minting a fresh flow id, so python's
    # same-URL loop detector never fires) and dies on the redirect budget
    # where Ansible lands on the final 200 page.
    #
    # Scope is the per-download jar semantics: cookies live and die with
    # one download, exactly like fetch_url's fresh CookieJar() per call -
    # no persistence between downloads.
    class CookieJar
      private record Stored,
        name : String, value : String, domain : String, path : String,
        secure : Bool, expires : Time?

      @cookies = [] of Stored

      # Stores the Set-Cookie headers of one response. Defaults follow
      # python's _cookie_from_cookie_tuple: a Domain attribute (lowercased,
      # stored in leading-dot form) is dropped unless it domain-matches the
      # request host; a missing Path becomes the request path's directory
      # (version-0 rule: up to but not including the last '/'); Max-Age
      # beats Expires, and a Max-Age/expiry at or before now is a delete
      # request for the stored cookie, not a store.
      def store(uri : URI, headers : HTTP::Headers) : Nil
        host = request_host(uri)
        return if host.empty?

        req_path = request_path(uri)
        now = Time.utc

        values = [] of String
        headers.each do |name, header_values|
          values.concat(header_values) if name.downcase == "set-cookie"
        end

        values.each do |header_value|
          cookie = parse_cookie(header_value, host, req_path, now)
          next if cookie.nil?

          index = @cookies.index do |stored|
            stored.name == cookie.name && stored.domain == cookie.domain &&
              stored.path == cookie.path
          end
          if index
            # python's jar replaces in place, keeping the original
            # creation order (its dict assignment preserves key order)
            @cookies[index] = cookie
          else
            @cookies << cookie
          end
        end
      end

      # The "name=value; name2=value2" Cookie header the jar contributes
      # for a request to `uri`, or nil when nothing matches. Ordering is
      # python's _cookie_attrs: most-specific (longest) path first, stable
      # for equal lengths (jar order).
      def cookie_header(uri : URI) : String?
        host = request_host(uri)
        return nil if host.empty?

        req_path = request_path(uri)
        secure_request = uri.scheme.to_s.downcase == "https"
        now = Time.utc

        matching = [] of {Stored, Int32}
        @cookies.each_with_index do |cookie, index|
          next unless domain_matches?(host, cookie.domain) &&
                      path_matches?(req_path, cookie.path) &&
                      !(cookie.secure && !secure_request) &&
                      !cookie.expires.try { |expires| expires <= now }
          matching << {cookie, index}
        end
        return nil if matching.empty?

        matching.sort_by! { |(cookie, index)| {-cookie.path.size, index} }
        matching.map { |(cookie, _)| "#{cookie.name}=#{cookie.value}" }.join("; ")
      end

      # One Set-Cookie header value -> a Stored cookie, or nil when python
      # would not have stored it (no name=value pair, a rejected domain,
      # an immediate expiry).
      private def parse_cookie(header_value : String, host : String, req_path : String, now : Time) : Stored?
        pair = header_value.split(';', 2)[0]
        eq = pair.index('=')
        return nil if eq.nil? || eq == 0
        name = pair[0...eq].strip
        return nil if name.empty?
        value = pair[(eq + 1)..].strip

        attrs = parse_attributes(header_value)
        return nil if attrs.bad

        if (domain = attrs.domain) && !domain_matches?(host, domain)
          # python's policy layer refuses to store a Domain attribute that
          # does not domain-match the request host
          return nil
        end

        expires, deleted = resolve_expiry(name, attrs, host, req_path, now)
        return nil if deleted

        Stored.new(name, value, attrs.domain || host, attrs.path || default_path(req_path), attrs.secure, expires)
      end

      private record Attrs,
        domain : String?, path : String?, secure : Bool,
        max_age : Int64?, expires_text : String?, bad : Bool

      # The ';' attributes after the name=value pair, python's
      # _normalized_cookie_tuples: a valueless Domain or a non-numeric
      # Max-Age marks the WHOLE cookie bad (dropped); Max-Age beats
      # Expires; unknown attributes (HttpOnly, SameSite, ...) are ignored.
      private def parse_attributes(header_value : String) : Attrs
        domain : String? = nil
        path : String? = nil
        secure = false
        max_age : Int64? = nil
        expires_text : String? = nil
        bad = false

        header_value.split(';').each_with_index do |attribute, position|
          next if position == 0
          attr_name, _, attr_value = attribute.partition('=')
          case attr_name.strip.downcase
          when "domain"
            raw = attr_value.strip.downcase
            if raw.empty?
              bad = true
            else
              domain = raw.starts_with?('.') ? raw : ".#{raw}"
            end
          when "path"
            candidate = attr_value.strip
            path = candidate unless candidate.empty?
          when "secure"
            secure = true
          when "max-age"
            begin
              max_age = attr_value.strip.to_i64
            rescue ArgumentError
              bad = true
            end
          when "expires"
            expires_text = attr_value.strip
          end
        end

        Attrs.new(domain, path, secure, max_age, expires_text, bad)
      end

      # The cookie's expiry from python's preference order, plus whether
      # the cookie is unstorable: a Max-Age of zero or less, or an expiry
      # at or before now, is a DELETE request for the stored cookie, not a
      # store (python clears the existing cookie and stores nothing).
      private def resolve_expiry(name : String, attrs : Attrs, host : String, req_path : String, now : Time) : {Time?, Bool}
        if max_age = attrs.max_age
          return deleted_expiry(name, attrs, host, req_path) if max_age <= 0
          {now + max_age.seconds, false}
        elsif text = attrs.expires_text
          expires = parse_http_date(text)
          return deleted_expiry(name, attrs, host, req_path) if expires && expires <= now
          {expires, false}
        else
          {nil, false}
        end
      end

      private def deleted_expiry(name : String, attrs : Attrs, host : String, req_path : String) : {Time?, Bool}
        remove(name, attrs.domain || host, attrs.path || default_path(req_path))
        {nil, true}
      end

      private def remove(name : String, domain : String, path : String) : Nil
        @cookies.reject! do |stored|
          stored.name == name && stored.domain == domain && stored.path == path
        end
      end

      # python's request_host/eff_request_host: the host lowercased, with
      # ".local" appended for dot-less non-IP names (so "localhost" and an
      # IP never blur into one scope).
      private def request_host(uri : URI) : String
        host = (uri.host || "").downcase
        return host if host.empty? || host.includes?('.') || ::Socket::IPAddress.valid?(host)
        "#{host}.local"
      end

      private def request_path(uri : URI) : String
        path = uri.path.to_s
        path = "/#{path}" unless path.starts_with?('/')
        path
      end

      # python's version-0 default path: the request path up to (not
      # including) its last '/', or "/" when that is empty.
      private def default_path(req_path : String) : String
        i = req_path.rindex('/')
        return "/" if i.nil?
        path = req_path[0...i]
        path.empty? ? "/" : path
      end

      # python's v0 return_ok_domain: (".erhn").ends_with?(dotdomain).
      # Host-only cookies were stored under the plain host (so this reads
      # as an exact match except for the liberal "x.host receives
      # host's cookie" quirk python itself has), Domain-attribute cookies
      # were stored in leading-dot form.
      private def domain_matches?(host : String, domain : String) : Bool
        dotdomain = domain.starts_with?('.') ? domain : ".#{domain}"
        ".#{host}".ends_with?(dotdomain)
      end

      # python's path_match (RFC 2965 3.3.4): equal paths, a prefix ending
      # in '/', or a prefix followed by '/'.
      private def path_matches?(req_path : String, cookie_path : String) : Bool
        return false unless req_path.starts_with?(cookie_path)
        cookie_path.ends_with?('/') || req_path.size == cookie_path.size ||
          req_path[cookie_path.size] == '/'
      end

      # http.cookiejar's http2time formats most likely to show up on real
      # Set-Cookie lines; anything unparsable degrades to a session cookie
      # (python treats an unparseable expires as absent).
      private def parse_http_date(text : String) : Time?
        Time::Format::RFC_2822.parse(text)
      rescue
        begin
          Time::Format::ISO_8601_DATE_TIME.parse(text)
        rescue
          begin
            Time::Format.new("%a %b %e %H:%M:%S %Y", Time::Location::UTC).parse(text)
          rescue
            nil
          end
        end
      end
    end
  end
end
