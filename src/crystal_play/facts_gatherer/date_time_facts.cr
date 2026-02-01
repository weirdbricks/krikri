require "json"

module CrystalPlay
  # DateTimeFacts - Gathers date and time facts
  module DateTimeFacts
    # Gather date/time facts
    # Populates: ansible_date_time (with epoch, iso8601, date, time, year, month, day, etc.)
    def self.gather(facts : Hash(String, JSON::Any), execute_callback : Proc(String, String?))
      # ansible_date_time - current date/time
      date_time = Hash(String, JSON::Any).new
      
      # epoch - Unix timestamp
      epoch = execute_callback.call("date +%s")
      date_time["epoch"] = JSON::Any.new(epoch.strip) if epoch
      
      # iso8601 - ISO 8601 format
      iso8601 = execute_callback.call("date -u +%Y-%m-%dT%H:%M:%SZ")
      date_time["iso8601"] = JSON::Any.new(iso8601.strip) if iso8601
      
      # date - YYYY-MM-DD
      date = execute_callback.call("date +%Y-%m-%d")
      date_time["date"] = JSON::Any.new(date.strip) if date
      
      # time - HH:MM:SS
      time = execute_callback.call("date +%H:%M:%S")
      date_time["time"] = JSON::Any.new(time.strip) if time
      
      # year, month, day
      year = execute_callback.call("date +%Y")
      date_time["year"] = JSON::Any.new(year.strip) if year
      
      month = execute_callback.call("date +%m")
      date_time["month"] = JSON::Any.new(month.strip) if month
      
      day = execute_callback.call("date +%d")
      date_time["day"] = JSON::Any.new(day.strip) if day
      
      # hour, minute, second
      hour = execute_callback.call("date +%H")
      date_time["hour"] = JSON::Any.new(hour.strip) if hour
      
      minute = execute_callback.call("date +%M")
      date_time["minute"] = JSON::Any.new(minute.strip) if minute
      
      second = execute_callback.call("date +%S")
      date_time["second"] = JSON::Any.new(second.strip) if second
      
      # weekday, weekday_number
      weekday = execute_callback.call("date +%A")
      date_time["weekday"] = JSON::Any.new(weekday.strip) if weekday
      
      weekday_number = execute_callback.call("date +%w")
      date_time["weekday_number"] = JSON::Any.new(weekday_number.strip) if weekday_number
      
      # timezone
      tz = execute_callback.call("date +%Z")
      date_time["tz"] = JSON::Any.new(tz.strip) if tz
      
      facts["ansible_date_time"] = JSON::Any.new(date_time) unless date_time.empty?
    end
  end
end
