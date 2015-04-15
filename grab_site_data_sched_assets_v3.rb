require 'csv'
require 'logger'
require 'set'
require 'nexpose'
require 'time'
require 'ipaddress'
require 'yaml'

include Nexpose


## Variables to Configure
$settings = YAML::load_file 'settings.yml'

NexposeIP = $settings[:nexpose][:host]
NexposeUN = $settings[:nexpose][:user]
NexposePW = $settings[:nexpose][:pass]


## Enter Credentials and IP for Nexpose connection
nsc = Connection.new(NexposeIP, NexposeUN, NexposePW)

## Enable Logging 
log = Logger.new(STDOUT)
log.level = Logger::INFO

## Get Current Date and Time
time = Time.new
set_date = time.strftime("%Y%m%d-%Hh%Mm")

## Login to Nexpose
log.debug "Logging in"
nsc.login

## Logout when the script exits
at_exit { nsc.logout }

## Get list of all Sites
begin
  retries = [3,5,10]
  sites = nsc.list_sites
## try to recover if we encounter network problems   
rescue Timeout::Error, Errno::ECONNRESET, Errno::ETIMEDOUT => e
  log.error e
  if delay = retries.shift
    sleep delay
    log.warn "Retrying site listing request..."
    retry
  else
    log.error "Retry attempts exceeded, can't proceed without site listing"
    exit(1)
  end
end

## Get list of all Engines
begin
  retries = [3,5,10]
  # Create array of engine pools and individual engines
  engines = nsc.list_engines
  engine_pools = nsc.list_engine_pools
 
rescue Timeout::Error, Errno::ECONNRESET, Errno::ETIMEDOUT => e
  log.error e
  if delay = retries.shift
    sleep delay
    log.warn "Retrying engine listing request..."
    retry
  else
    log.error "Retry attempts exceeded, can't proceed without engine listing"
    exit(1)
  end
end

## Create a CSV file to write data to
CSV.open("Sitedata-#{set_date}.csv", 'w') do |row|

  ## Create Column Headers for data
  row << ["Site Name", "Site ID", "Defined Assets", "Asset Count", "IP Include", "IP Exclude", "Site Description", "Scan Template", "Scan Template ID", "Scan Engine", "Scan Schedule", "Scan Schedule Type", "Scan Schedule Interval", "Scan Schedule Start Date", "Scan Schedule Day of Week","Scan Schedule Start Time", "Scan Schedule Max Dur", "Scan Schedule Repeat", "Scan Schedule Enabled", "Last Scan Duration"]

  ## Loop through each Site to collect the Site data
  sites.each do |site_detail|

    defined_assets = 0

    ## Store the Site Name
    site_name = site_detail.name

    ## Store the Site ID
    site_id = site_detail.id

    ## Load the Site
    begin
      retries = [3,5,10]
      site = Nexpose::Site.load(nsc, site_id)
      log.info "Loaded site configuration for #{site_name} (id: #{site_id})"
    rescue Timeout::Error, Errno::ECONNRESET, Errno::ETIMEDOUT => e
      log.error e
      if delay = retries.shift
        sleep delay
        log.warn "Retrying site config request for #{site_name} (id: #{site_id})..."
        retry
      else
        log.error "Retry attempts exceeded, skipping #{site_name} (id: #{site_id})"
        next
      end
    end

    ## Initialize variables to store Included and Excluded assets
    ip_range_include = []
    ip_range_exclude = []

    ## Store the Site's Included Assets
    site_assets_include = site.assets

    ## Loop through the Included Assets to enumerate them
    site_assets_include.each do |ip_array|
      next if ip_array.nil?
      begin
        ip_range_first = ip_array.from.to_s
        ip_range_last  = ip_array.to.to_s
        if ip_array.to.nil?
          ip_range_include << ip_range_first
          defined_assets += 1
        else
          ip_range_include << ip_range_first + ' - ' + ip_range_last
          defined_assets += (IPAddress(ip_range_last) - IPAddress(ip_range_first))+1
        end
      rescue
        ip_range_include << ip_array.host
        defined_assets += 1
      end
    end
	
    ##	if defined_assets > 9000
    ##		ip_range_include.clear
    ##		ip_range_include << "error"
    ##	end
	
    ## Loop through the Excluded Assets to enumerate them
    site_assets_exclude = site.exclude
    site_assets_exclude.each do |ip_array|
      next if ip_array.nil?
      begin
        ip_range_first = ip_array.from.to_s
        ip_range_last  = ip_array.to.to_s
        if ip_array.to.nil?
          ip_range_exclude << ip_range_first
		  defined_assets -= 1
        else
          ip_range_exclude << ip_range_first + ' - ' + ip_range_last
		  excluded = (IPAddress(ip_range_last) - IPAddress(ip_range_first))+1
		  defined_assets -= excluded
        end
      rescue
        ip_range_exclude << ip_array.host
		defined_assets -= 1	
      end
    end

    begin

      ## Get the details for the Last Scan for each Site
      begin
        retries = [3,5,10]
        last_scan = nsc.last_scan(site.id)
      rescue Timeout::Error, Errno::ECONNRESET, Errno::ETIMEDOUT => e
        log.error e
        if delay = retries.shift
          sleep delay
          log.warn "Retrying last scan id request for #{site_name} (id: #{site_id})..."
          retry
        else
          log.error "Retry attempts exceeded, proceeding without last scan data"
          raise "Retry attempts exceeded"
        end
      end

      ## Get the Start and End time of the Last Scan
      start_scan_dur =  last_scan.start_time
      end_scan_dur =  last_scan.end_time

      ## Find the Duration of the Last Scan
      t = Time.parse(end_scan_dur.to_s)-Time.parse(start_scan_dur.to_s)

      mm, ss = t.divmod(60)            #=> [4515, 21]
      hh, mm = mm.divmod(60)           #=> [75, 15]
      dd, hh = hh.divmod(24)           #=> [3, 3]
      time_diff_dur =  "%d days, %d hours, %d minutes and %d seconds" % [dd, hh, mm, ss]

      ## Find out the Live Assets that were discovered in the Last Scan
      live_assets = last_scan.nodes.live
    rescue
      live_assets = 0
      time_diff_dur = "N/A"
    end

    ## Get the Site Description
    site_desc = site.description

    ## Get the Scan Schedule
    schedule = site.schedules
    schedule_full = ""
    sched_type = ""
    sched_interval = ""
    sched_start = ""
    sched_enabled = ""
    sched_incremental = ""
    sched_maxdur = ""
    sched_repeater = ""
    sched_time = ""
    day_of_week = ""
    schedule.each do |element|
      sched_type = element.type
      sched_interval = element.interval
      sched_start_date = element.start
      sched_start = sched_start_date[0..7]
      start_date = sched_start
      sched_time = sched_start_date[9..12]
      start_time = sched_time
      time = Time.local(start_date[0..3],start_date[4..5],start_date[6..7],start_time[0..1],start_time[2..3],0)
      time_est = time - 25200  ## 14400 for EST
      time_formatted = time_est.strftime("%H%M")
            day_of_week = time.strftime("%A")

      sched_time = time_formatted

      sched_enabled = element.enabled
      sched_incremental = element.incremental
      sched_maxdur = element.max_duration
      sched_repeater = element.repeater_type
      schedule_full = sched_type.to_s + ',' + sched_interval.to_s + ',' + sched_start.to_s + ',' + time_formatted.to_s + ',' + sched_maxdur.to_s + ',' + sched_repeater.to_s
    end

    ## Determine which Engine is being used to Scan the Site
    
all_engines = engines.concat(engine_pools)
engine = all_engines.find{|e| e.id.to_i == site.engine}
engine_name = engine.name
              
   
    ## Populate CSV with Site data
    row << [site_name,site_id, defined_assets, live_assets, ip_range_include.join("\n"),ip_range_exclude.join("\n"), site_desc, site.scan_template_name, site.scan_template, engine_name, schedule_full, sched_type, sched_interval, sched_start, day_of_week, sched_time, sched_maxdur, sched_repeater, sched_enabled, time_diff_dur]

  end
end
