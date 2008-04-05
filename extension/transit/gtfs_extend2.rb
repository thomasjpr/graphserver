require 'google_transit_feed'

require 'rubygems'
#require_gem 'tzinfo'
#gem 'tzinfo'
require 'tzinfo'
include TZInfo

class Graphserver
  WGS84_LATLONG_EPSG = 4326
  GTFS_PREFIX = "gtfs"
  SECONDS_IN_DAY = 86400

  def load_service_ids
    #initialize sid_numbers as a hash, where each service_id
    #will be assigned a number starting from zero
    sid_numbers = {}

    #=========GET SERVICE_IDs, ASSOCIATE THEM WITH INTs=====
    service_ids = conn.exec <<-SQL
      SELECT *
      FROM (SELECT service_id
            FROM gtf_calendar
            UNION
            SELECT service_id
            FROM gtf_calendar_dates) AS foo
      ORDER BY service_id
    SQL

    #service_ids are internally represented in as numbers. So we make the shift here.
    service_ids.each do |service_id|
      sid_numbers[service_id.first] = sid_numbers.size
    end

    sid_numbers
  end

  #optionally specify the agency who's calendary you want to load
  #if no agency is specified, uses the first one in the agencies table
  def load_calendar agency_id=nil
    expanded_calendar = {}

    #=========GET SERVICE_IDs, ASSOCIATE THEM WITH INTs=====
    sid_numbers = load_service_ids

    #=========FIGURE OUT THE SERVICE DAY BOUNDS=============

    day_bounds = conn.exec <<-SQL
      select min(departure_time), max(arrival_time) from gtf_stop_times
    SQL

    #convert day_bounds to seconds since beginning of local midnight
    sid_start = GoogleTransitFeed::parse_time( day_bounds[0][0] )
    sid_end   = GoogleTransitFeed::parse_time( day_bounds[0][1] )

    #pop an error if service days overlap
    #if sid_end-sid_start > SECONDS_IN_DAY then raise "Service day spans #{day_bounds[0][0]} to #{day_bounds[0][1]}; Service days may not overlap" end

    #=========GET TIMEZONE INFORMATION======================
    if agency_id then
      timezone = conn.exec "SELECT agency_timezone FROM gtf_agency WHERE agency_id='#{agency_id}'"
    else
      timezone = conn.exec "SELECT agency_timezone FROM gtf_agency"
    end
    timezone = TZInfo::Timezone.get( timezone[0][0] ) #convert timezone string (eg "America/New York") to timezone
    tz_offset  = timezone.current_period.utc_offset                  #number of seconds offset from UTC (eg -18000)
    dst_offset = timezone.current_period.std_offset                  #number of seconds changed during daylight savings eg 3600

    #=========EXPAND calendar TABLE INTO HASH===============
    dates = conn.exec <<-SQL
      SELECT service_id, monday, tuesday, wednesday, thursday, friday, saturday, sunday, start_date, end_date from gtf_calendar
    SQL

    #for each service_id in the calendar table
    dates.each do |service_id, mon, tue, wed, thu, fri, sat, sun, start_date, end_date|
      #convert to boolean daymask
      daymask = [mon, tue, wed, thu, fri, sat, sun].collect do |day| day == "1" end

      #Find the UTC date, as if we're in London
      i = GoogleTransitFeed::parse_date( start_date )  #date as parsed to UTC
      n = GoogleTransitFeed::parse_date( end_date )    #end date is inclusive

      #the expanded calendar is a hash with the dates where services run as keys and
      #the service_ids of particular services running each day as values, grouped in arrays
      #for each day in the service_id date range
      while i <= n  do
        if daymask[ i.wday ] then
          expanded_calendar[i] ||= []
          expanded_calendar[i] << sid_numbers[service_id]
        end

        i += SECONDS_IN_DAY
      end
    end

    #=========APPLY EXCEPTIONS FROM calendar_dates TO expanded_calendar HASH=============
    single_dates = conn.exec <<-SQL
      SELECT service_id, date, exception_type from gtf_calendar_dates
    SQL

    single_dates.each do |service_id, date, exception_type|
      #returns UTC date, as if we're in London
      i = GoogleTransitFeed::parse_date( date )
      #if the key=>value pair doesn't exist, creates it, elsewhere it does nothing
      expanded_calendar[i] ||= []

      if exception_type == "1" then
        expanded_calendar[i] << sid_numbers[service_id]
      elsif exception_type == "2" then
        expanded_calendar[i].delete sid_numbers[service_id]
      end
    end

    #========CONVERT EXPANDED CALENDAR TO SORTED ARRAY===================================
    expanded_calendar = expanded_calendar.to_a
    expanded_calendar.sort! do |a,b|
      a.first <=> b.first
    end

    #========CONVERT SORTED ARRAY INTO CALENDAR OBJECT===================================
    ret = Calendar.new
    expanded_calendar.each do |day, service_ids|
      local_daystart = day.to_i-tz_offset
      #if daylight savings is in effect
      if timezone.period_for_utc( day.to_i ).dst? then
        local_daystart -= dst_offset
        daylight_savings = dst_offset
      else
        daylight_savings = 0
      end

      ret.append_day( local_daystart+sid_start, local_daystart+sid_end, service_ids, daylight_savings )
    end

    return ret.rewind!
  end

  # Returns a hash with all increments from the first departure time for each trip in gtf_frequencies
  def load_frequencies
    frequencies = {}

    frequencies_table = conn.exec <<-SQL
      SELECT * FROM gtf_frequencies
    SQL

    frequencies_table.each do |trip_id, start_time, end_time, headway_secs|
      st = GoogleTransitFeed::parse_time( start_time )
      et = GoogleTransitFeed::parse_time( end_time )
      hs = headway_secs.to_i
      # If there is not a key in the hash then creates the key
      frequencies[trip_id] ||=[]
      # Fills all the starting times for the trip
      while st <= et
        frequencies[trip_id] << st
        st += hs
      end
    end

    # Traverse the frequencies hash and subtract the first start time from all values
    frequencies.each do |key, row|
      first = row[0]
      frequencies[key] = []
      row.each do |f|
        frequencies[key] << f - first
      end
    end
    return frequencies
  end

  def load_triphops

    sid_numbers = load_service_ids

    triphops = {}
    print "Querying Triphops\n"
    stop_times = conn.exec <<-SQL
      SELECT t1.trip_id,
             t1.stop_id AS from_id,
             t2.stop_id AS to_id,
             t1.departure_time,
             t2.arrival_time,
--             t1.stop_sequence,
             gtf_trips.service_id
      FROM gtf_stop_times AS t1,
           gtf_stop_times AS t2,
           gtf_trips
      WHERE t2.trip_id = t1.trip_id AND
            t2.stop_sequence = t1.stop_sequence+1 AND
            t1.trip_id = gtf_trips.trip_id
      ORDER BY trip_id, t1.stop_sequence
    SQL
    print "done\n"

    #load frequencies from frequencies table
    frequencies = load_frequencies

    print "Interpolating and sorting triphops\n"
    n=stop_times.num_tuples
    i=0
    prev_timed=0
    stop_times.each do |trip_id, from_id, to_id, departure_time, arrival_time, service_id|
      if departure_time then
        # Looks for dep=something arr=something pattern, which triggers regular behaviour
        if arrival_time then
          schedule_key = [from_id, to_id, sid_numbers[service_id]]
          triphops[schedule_key] ||= []
          dt = GoogleTransitFeed::parse_time( departure_time )
          at = GoogleTransitFeed::parse_time( arrival_time )
#          duration = at - dt
          # If the trip has an associated frequency
          if frequencies[trip_id] then
            frequencies[trip_id].each do |f|
              triphops[schedule_key] << [dt + f, at + f , trip_id ]
            end
          else
            triphops[schedule_key] << [dt, at, trip_id ]
          end
        # Looks for dep=something arr=nil pattern
        else # if arrival_time
          prev_timed=i
        end  # if arrival_time
      else # if departure_time
        # Looks for dep=nil arr=something pattern which triggers interpolation
        if arrival_time then
          first_time = GoogleTransitFeed::parse_time( stop_times[prev_timed][3] )
          last_time = GoogleTransitFeed::parse_time( stop_times[i][4] )
          # The time step is linearly interpolated (not based on distance)
          step = (last_time-first_time)/(i-prev_timed+1)
          dep_time = first_time
          arr_time = dep_time + step
          # Interpolate times and feed triphops hash
          for j in prev_timed..i
            schedule_key = [stop_times[j][1], stop_times[j][2], sid_numbers[service_id]]
            triphops[schedule_key] ||= []
            # If the trip has an associated frequency
            if frequencies[trip_id] then
              frequencies[trip_id].each do |f|
                triphops[schedule_key] << [dep_time + f, arr_time + f, trip_id ]
              end
            else
              triphops[schedule_key] << [dep_time, arr_time, trip_id ]
            end
            dep_time = arr_time
            arr_time += step
          end
        end # if arrival_time

      end # if departure_time
      i += 1
      if i%1000==0 then $stderr.print( sprintf( "\rChecked %d/%d trip hops (%d%%)", i, n, (i.to_f/n)*100 ) ) end
    end #stop_times.each
    $stderr.print( "...done\n" )

    return triphops
  end

  def load_google_transit_feed agency_id=nil
    #=========GET TIMEZONE INFORMATION======================
    if agency_id then
      timezone = conn.exec "SELECT agency_timezone FROM gtf_agency WHERE agency_id='#{agency_id}'"
    else
      timezone = conn.exec "SELECT agency_timezone FROM gtf_agency"
    end
    timezone = TZInfo::Timezone.get( timezone[0][0] ) #convert timezone string (eg "America/New York") to timezone
    tz_offset  = timezone.current_period.utc_offset                  #number of seconds offset from UTC (eg -18000)

    #=========LOAD CALENDAR=================================

    calendar = load_calendar( agency_id )

    #service_ids are numbers in graphserver
    #sid_numbers is a service_id -> number dictionary
    sid_numbers = load_service_ids

    #load vertices
    print "Loading stops..."
    stops = conn.exec "SELECT stop_id FROM gtf_stops"
    stops.each do |stop|
      @gg.add_vertex( GTFS_PREFIX+stop.first )
    end
    print "done\n"

    #load triphops from stop_times table
    triphops = load_triphops

    #dump triphops to graphserver
    print "Importing triphops to Graphserver\n"
    triphops.each_pair do |sched_key, sched|
      from_id, to_id, service_id = sched_key
      @gg.add_edge( GTFS_PREFIX+from_id, GTFS_PREFIX+to_id, TripHopSchedule.new( service_id, sched, calendar, tz_offset ) )
    end

    return true
  end

  #links nearby stops with a direct line-of-sight
  def link_stops_los
    search_range = 0.03 #decimal degrees lat/long around a stop to look for nearby stops
    num_links = 30
    stops = conn.exec "SELECT stop_id, location FROM gtf_stops"

    n = stops.num_tuples; i=0

    stops.each do |from_id, location|
      @gg.add_vertex( GTFS_PREFIX+from_id )

      i += 1
      if i%10==0 then $stderr.print( sprintf("\rLinked %d/%d stops (%d%%)", i, n, (i.to_f/n)*100) ) end

      nearby_stops = conn.exec <<-SQL
        SELECT stop_id, distance_sphere( '#{location}'::geometry, location ) AS dist
        FROM gtf_stops
        WHERE location && expand( '#{location}'::geometry, #{search_range} )
        ORDER BY dist
        LIMIT #{num_links}
      SQL

      nearby_stops.each do |to_id, dist|
        @gg.add_vertex( GTFS_PREFIX+to_id )
        @gg.add_edge( GTFS_PREFIX+from_id, GTFS_PREFIX+to_id, Street.new( "LOS", dist.to_f ) )
      end
    end

    $stderr.print( "...done.\n" )

  end

  def create_gtfs_tables!
    conn.exec <<-SQL
      BEGIN;

      create table gtf_agency (
        agency_id          text,
        agency_name        text NOT NULL,
        agency_url         text NOT NULL,
        agency_timezone    text NOT NULL,
        agency_lang        text
      );

      create table gtf_stops (
        stop_id          text PRIMARY KEY,
        stop_name        text NOT NULL,
        stop_desc        text,
        stop_lat         numeric,
        stop_lon         numeric,
        zone_id          numeric,
        stop_url         text,
        stop_code        text
      );

      select AddGeometryColumn( 'gtf_stops', 'location', #{WGS84_LATLONG_EPSG}, 'POINT', 2 );
      CREATE INDEX gtf_stops_location_ix ON gtf_stops USING GIST ( location GIST_GEOMETRY_OPS );

      create table gtf_routes (
        route_id          text PRIMARY KEY,
        agency_id         text,
        route_short_name  text DEFAULT '',
        route_long_name   text NOT NULL,
        route_desc        text,
        route_type        numeric,
        route_url         text,
        route_color       text,
        route_text_color  text
      );

      create table gtf_trips (
        route_id      text NOT NULL,
        service_id    text NOT NULL,
        trip_id       text PRIMARY KEY,
        trip_headsign text,
        direction_id  numeric,
        block_id      text,
        shape_id      text
      );

      create table gtf_stop_times (
        trip_id             text NOT NULL,
        arrival_time        text,
        departure_time      text,
        stop_id             text,
        stop_sequence       numeric NOT NULL,
        stop_headsign       text,
        pickup_type         numeric,            --see google feed spec
        drop_off_type       numeric,            --see google feed spec
        shape_dist_traveled numeric
      );

      CREATE INDEX gst_trip_id_stop_sequence ON gtf_stop_times (trip_id, stop_sequence);

      create table gtf_calendar (
        service_id   text PRIMARY KEY,
        monday       numeric NOT NULL,
        tuesday      numeric NOT NULL,
        wednesday    numeric NOT NULL,
        thursday     numeric NOT NULL,
        friday       numeric NOT NULL,
        saturday     numeric NOT NULL,
        sunday       numeric NOT NULL,
        start_date   date NOT NULL,
        end_date     date NOT NULL
      );

      create table gtf_calendar_dates (
        service_id     text NOT NULL,
        date           date NOT NULL,
        exception_type numeric NOT NULL
      );

      create table gtf_fare_attributes (
        fare_id           text PRIMARY KEY,
        price             numeric NOT NULL,
        currency_type     text NOT NULL,
        payment_method    numeric NOT NULL,
        transfers         numeric,
        transfer_duration numeric
      );

      create table gtf_fare_rules (
        fare_id           text NOT NULL,
        route_id          text,
        origin_id         numeric,
        destination_id    numeric,
        contains_id       numeric
      );

      create table gtf_shapes (
        shape_id                text PRIMARY KEY
      );

      select AddGeometryColumn( 'gtf_shapes', 'shape', #{WGS84_LATLONG_EPSG}, 'LINESTRING', 2 );

      create table gtf_frequencies (
        trip_id           text NOT NULL,
        start_time        text NOT NULL,
        end_time          text NOT NULL,
        headway_secs      numeric NOT NULL
      );
      COMMIT;

      SQL

  end

  def remove_gtfs_tables!

    begin
      conn.exec "drop table gtf_agency"
      conn.exec "drop table gtf_stops"
      conn.exec "drop table gtf_routes"
      conn.exec "drop table gtf_trips"
      conn.exec "drop table gtf_stop_times"
      conn.exec "drop table gtf_calendar"
      conn.exec "drop table gtf_calendar_dates"
      conn.exec "drop table gtf_fare_attributes"
      conn.exec "drop table gtf_fare_rules"
      conn.exec "drop table gtf_shapes"
      conn.exec "drop table gtf_frequencies"
    rescue
      nil
    end

  end

#  def remove_gtfs_tables!
#
#    begin
#      conn.exec <<-SQL
#        BEGIN;
#        drop table gtf_agency;
#        drop table gtf_stops;
#        drop table gtf_routes;
#        drop table gtf_trips;
#        drop table gtf_stop_times;
#        drop table gtf_calendar;
#        drop table gtf_calendar_dates;
#        drop table gtf_fare_attributes;
#        drop table gtf_fare_rules;
#        drop table gtf_shapes;
#        drop table gtf_frequencies;
#        COMMIT;
#      SQL
#    rescue
#      nil
#    end
#
#  end

  def import_google_transit_file( gtf_file, table_name )
    return nil if not gtf_file or gtf_file.header.empty?
    print "Importing #{table_name}.txt file\n"

    conn.exec "COPY #{table_name} ( #{gtf_file.header.join(",")} ) FROM STDIN"

    fsize = gtf_file.data.size
    count=0

    gtf_file.data.each do |row|
      row = Array.new( gtf_file.header.size ) do |i|
        if row[i] and not row[i].empty? then row[i] else "\\N" end
      end
      conn.putline(row.join("\t") + "\n")

      if (count%5000)==0 then
        print "#{(Float(count)/fsize)*100}%\n"
      end
      count += 1
    end

    conn.endcopy
  end

  def import_google_transit_stops_file( stops_file )
    return nil if not stops_file or stops_file.header.empty?
    print "Importing stops.txt file\n"

    stop_lat_index = stops_file.header.index("stop_lat")
    stop_lon_index = stops_file.header.index("stop_lon")

    conn.exec "COPY gtf_stops ( #{stops_file.header.join(",")}, location ) FROM STDIN"
    header_len = stops_file.header.length
    stops_file.data.each do |row|
      shape_wkt = "SRID=#{WGS84_LATLONG_EPSG};POINT(#{row[stop_lon_index]} #{row[stop_lat_index]})"
      row += [""] * (header_len - row.length) if row.length != header_len #added this to parse trimet
      row.collect! do |item| if item.empty? then "\\N" else item end end
      conn.putline "#{row.join("\t")}\t#{shape_wkt}\n"
    end

    conn.endcopy
  end

  #Necessary to parse arrival_time and departure_time defined as "H:MM:SS" instead of "HH:MM:SS"
  def import_google_transit_stop_times_file( stop_times_file )
    return nil if not stop_times_file or stop_times_file.header.empty?
    print "Importing stop_times.txt file\n"

    conn.exec "COPY gtf_stop_times ( #{stop_times_file.header.join(",")} ) FROM STDIN"

    header_len = stop_times_file.header.length
    stop_times_file.data.each do |row|
      row += [""] * (header_len - row.length) if row.length != header_len #added this to parse trimet
      if row[1]!='' then row[1]=row[1].rjust(8,'0') end
      if row[2]!='' then row[2]=row[2].rjust(8,'0') end
      row.collect! do |item| if item.empty? then "\\N" else item end end
      conn.putline "#{row.join("\t")}\n"
    end

    conn.endcopy
  end

  def import_google_transit_shapes_file( shapes_file )
    return nil if not shapes_file or shapes_file.header.empty?
    print "Importing shapes.txt file\n"

    shapes = {}
    shapes_file.data.each do |shape_id, lat, lon, sequence|
      shapes[shape_id] ||= []
      shapes[shape_id][sequence.to_i-1] = [lat, lon]
    end

    conn.exec "COPY gtf_shapes ( shape_id, shape ) FROM STDIN"

    shapes.each_pair do |shape_id, shape|
      shape_wkt = "SRID=#{WGS84_LATLONG_EPSG};LINESTRING( " + shape.collect do |point| "#{point[0]} #{point[1]}" end.join(",") + ")"
      conn.putline "#{shape_id}\t#{shape_wkt}\n"
    end

    conn.endcopy
  end


  def import_gtfs_to_db! directory
    gt = GoogleTransitFeed::GoogleTransitFeed.new( directory, :verbose )

    import_google_transit_file( gt["agency"],          "gtf_agency" )
    import_google_transit_stops_file( gt["stops"] )
    import_google_transit_file( gt["routes"],          "gtf_routes" )
    import_google_transit_file( gt["trips"],           "gtf_trips" )
#    import_google_transit_file( gt["stop_times"],      "gtf_stop_times" )
    import_google_transit_stop_times_file( gt["stop_times"] )
    import_google_transit_file( gt["calendar"],        "gtf_calendar" )
    import_google_transit_file( gt["calendar_dates"],  "gtf_calendar_dates" )
    import_google_transit_file( gt["fare_attributes"], "gtf_fare_attributes" )
    import_google_transit_file( gt["fare_rules"],      "gtf_fare_rules" )
    import_google_transit_shapes_file( gt["shapes"] )
    import_google_transit_file( gt["frequencies"],     "gtf_frequencies" )
  end

end