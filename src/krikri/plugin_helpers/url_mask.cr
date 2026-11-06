module Krikri
  module PluginHelpers
    # ansible-core 2.21's module_utils/urls.py mask_url(): the URL's
    # userinfo (username, and password when there is one) is replaced with
    # "****" everywhere a module reports a url: back, so credentials typed
    # into a task stop leaking into module output.
    #
    # Exactly like the Python original this is a plain string replace on
    # the netloc, using the RAW userinfo text (Python's urlparse does not
    # decode %XX there, so neither does this): a URL whose userinfo does
    # not literally appear is returned byte for byte, as is one without
    # any userinfo at all.
    module UrlMask
      MASK = "****"

      def self.mask(url : String) : String
        prefix, netloc, rest = split(url)
        return url if netloc.empty?

        at = netloc.rindex('@')
        return url unless at
        userinfo = netloc[0, at]
        colon = userinfo.index(':')
        username = colon ? userinfo[0, colon] : userinfo
        password = colon ? userinfo[colon + 1..] : ""

        # Python picks the branch on the password's truthiness, then on the
        # username's - so "user:@host" (an empty password) is left alone,
        # while ":pass@host" masks, and an entirely empty userinfo is never
        # touched (the original's early return).
        target, replacement = if !password.empty?
                                {"#{username}:#{password}@", "#{MASK}:#{MASK}@"}
                              elsif !username.empty?
                                {"#{username}@", "#{MASK}@"}
                              else
                                return url
                              end
        return url unless netloc.includes?(target)

        "#{prefix}#{netloc.gsub(target, replacement)}#{rest}"
      end

      # Splits off the scheme prefix ("scheme://", or a bare "//" for a
      # scheme-relative URL) and the netloc, which ends at the first /, ?
      # or # exactly like Python's urlparse.
      private def self.split(url : String) : {String, String, String}
        if (scheme_end = url.index("://"))
          prefix = url[0, scheme_end + 3]
        elsif url.starts_with?("//")
          prefix = "//"
        else
          return {"", "", url}
        end
        tail = url[prefix.size..]
        stop = [tail.index('/'), tail.index('?'), tail.index('#')].compact.min? || tail.size
        {prefix, tail[0, stop], tail[stop..]}
      end
    end
  end
end
