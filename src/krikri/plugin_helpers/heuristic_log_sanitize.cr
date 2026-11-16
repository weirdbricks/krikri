module Krikri
  module PluginHelpers
    # AnsibleModule.run_command composes a check_rc failure's `msg` as
    # heuristic_log_sanitize(stderr.rstrip()) (module_utils/basic.py) while
    # keeping the raw text in the `stderr`/`stdout` keys. The helper is
    # deliberately crude: from each '@' it rewinds to the nearest preceding
    # '://' (or the start of the string) and blanks everything up to the
    # next ':' after that scheme. Its own docstring admits the false
    # positives - a failed `npm install` prints
    #
    #   npm ERR! 404 Not Found - GET https://registry.npmjs.org/pkg - ...
    #   npm ERR! 404  'pkg@1.2.3' is not in this registry.
    #
    # and real ansible reports the display text as
    # "GET https:********@1.2.3' is not in this registry.", dropping the
    # lines in between. Reproducing the algorithm byte for byte is what
    # keeps a failed module's msg identical to real ansible's.
    module HeuristicLogSanitize
      extend self

      def sanitize(data : String) : String
        output = [] of String
        start = data.bytesize
        prev_begin = start
        sep : Int32? = 1
        while sep
          end_pos = start > 0 ? data.rindex('@', start - 1) : nil
          unless end_pos
            output.insert(0, data.byte_slice(0, start))
            break
          end

          sep = nil
          sep_search_end = end_pos
          loop do
            url = sep_search_end >= 3 ? data.rindex("://", sep_search_end - 1) : nil
            start = url || 0
            colon = data.index(':', start + 3)
            if colon && colon < end_pos
              sep = colon
              break
            elsif start == 0
              output.insert(0, data.byte_slice(0, prev_begin))
              break
            else
              sep_search_end = start
            end
          end

          if sep
            output.insert(0, data.byte_slice(end_pos, prev_begin - end_pos))
            output.insert(0, "********")
            output.insert(0, data.byte_slice(start, sep + 1 - start))
            prev_begin = start
          end
        end
        output.join
      end
    end
  end
end
