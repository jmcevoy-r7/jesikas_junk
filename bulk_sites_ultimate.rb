require 'csv'
require 'logger'
require 'set'
gem 'nexpose', '>0.5'
require 'nexpose'
##require 'ip'
##require 'ipaddress'

include Nexpose

## Enable Logging so that all Site Creation and Modification are tracked
log = Logger.new(STDOUT)
log.level = Logger::INFO

## Variables to Configure
$settings = YAML::load_file 'settings.yml'

NexposeIP = $settings[:nexpose][:host]
NexposeUN = $settings[:nexpose][:user]
NexposePW = $settings[:nexpose][:pass]


## Enter Credentials and IP for Nexpose connection
nsc = Connection.new(NexposeIP, NexposeUN,NexposePW)

## Data structure to describe imported site data from CSV
class SiteInfo
  attr_accessor :name, :template, :engine, :schedule, :description, :included, :excluded

  def initialize(name)
    @name = name
    @included = []
    @excluded = []
  end
end

## Create a hash of sites to import to Nexpose
sites_to_import = {}

## Parse through CSV to populate the hash that was created in the previous step
CSV.foreach('sitelist_detail.csv', {:headers => true, :encoding => "ISO-8859-15:UTF-8"}) do |row|
  ##puts row
  name = row['Site Name']
  site = sites_to_import[name]
  if site.nil?
    log.debug "Site #{name} found in CSV file"
    site = SiteInfo.new(name)
    sites_to_import[name] = site
  end
  site.template = row['Scan Template ID'] if row['Scan Template ID']
  site.engine = row['Scan Engine Name'] if row['Scan Engine Name']
  site.schedule = row['Scan Schedule'] if row['Scan Schedule']
  site.description = row['Description'] if row['Description']
  site.included << row['IP Include'].to_s.strip if row['IP Include']
  site.excluded << row['IP Exclude'].to_s.strip if row['IP Exclude']
end

## Get a listing of sites and engines
log.debug "Logging in"
nsc.login
at_exit { nsc.logout }

begin
  retries = [3,5,10]
  site_listing = nsc.list_sites
## try to recover if we encounter network problems   
rescue Timeout::Error, Errno::ECONNRESET, Errno::ETIMEDOUT => e
  log.error e
  if delay = retries.shift
    sleep delay
    log.warn "Retrying... - #{site_import.name}"
    retry
  else
    log.error "Retry attempts exceeded, can't proceed without site listing"
    exit(1)
  end
end

begin
  retries = [3,5,10]
  #  engine_listing = nsc.list_engines
  engine_pools = nsc.list_engine_pools
## try to recover if we encounter network problems   
rescue Timeout::Error, Errno::ECONNRESET, Errno::ETIMEDOUT => e
  log.error e
  if delay = retries.shift
    sleep delay
    log.warn "Retrying... - #{site_import.name}"
    retry
  else
    log.error "Retry attempts exceeded, can't proceed without engine listing"
    exit(1)
  end
end

## For each site, check if exists, create if needed, then save configuration
sites_to_import.each do |site_import|
  site_import = site_import[1]
  log.debug "Working on site - #{site_import.name}"  
  begin
    ## if site exists, load it, otherwise create a new one
    site = site_listing.select {|site_summary| site_summary.name == site_import.name}
    log.debug "Checking if site exists - #{site_import.name} - #{site}"
    log.debug "Included IPs - #{site_import.included}"
    log.debug "Excluded IPs - #{site_import.excluded}"
    begin
      log.debug "#{site_import.name} found"
      site = Site.load(nsc, (site[0].id))
    rescue
      log.debug "#{site_import.name} not found"
      site = Site.new(site_import.name) 
    end

    ## set the description and scan template if defined in CSV file
    site.description = site_import.description if site_import.description
    site.scan_template = site_import.template if site_import.template

    ## set the engine id if found based on engine name
    engine = engine_pools.select{|engine_summary| engine_summary.name == site_import.engine}
    unless engine[0].nil?
      site.engine = engine[0].id
    end
    
    ## add the schedule
    if site_import.schedule.to_s != ""
      ## convert the schedule string into a suitable format for Nexpose
      schedule_items = site_import.schedule.to_s.split ","
      log.debug site_import.schedule.to_s
      start_date = schedule_items[2]
      start_time = schedule_items[3]
      time = Time.local(start_date[0..3],start_date[4..5],start_date[6..7],start_time[0..1],start_time[2..3],0)
      time_est = time + 14400
      time_formatted = time_est.strftime("%Y%m%dT%H%M00000")

      ## create the schedule and add it to the site configuration
      schedule = Schedule.new(schedule_items[0],schedule_items[1],time_formatted,enabled=true)
      schedule.max_duration = schedule_items[4]
      schedule.repeater_type = schedule_items[5]
      site.schedules << schedule
    end

     ## add the included IP addresses/ranges to the site configuration
    site_import.included.each do |ip|
      next if ip.empty?
      if ip.include? '-'
        begin
        from, to = ip.split(' - ')
        rescue
          from, to = ip.split('-')
          end
        site.add_ip_range(from, to)
      else

        ip_new = IPAddr.new(ip)
        site.add_ip_range(ip_new.to_range.first.to_s, ip_new.to_range.last.to_s)
      end
    end

    ## add the excluded IP addresses/ranges to the site configuration
    site_import.excluded.each do |ip|
      next if ip.empty?
        if ip.split(' - ').size == 2
          from, to = ip.split(' - ')
          site.exclude <<  IPRange.new(from, to)
        else
          ##puts ip
          ip_new = IPAddr.new(ip)
          site.exclude <<  IPRange.new(ip_new.to_range.first.to_s, ip_new.to_range.last.to_s)
        end
        ##site.exclude << ip
    end

    ## save the site configuration
    begin
      retries = [3,5,10]

      site.save(nsc)
      log.info "Saved site #{site.name} (id:#{site.id})"
    ## try to recover if we encounter network problems   
    rescue Timeout::Error, Errno::ECONNRESET, Errno::ETIMEDOUT => e
      log.error e
      if delay = retries.shift
        sleep delay
        log.warn "Retrying... - #{site_import.name}"
        retry
      else
        log.warn "Retry attempts exceeded, moving on to the next site - #{site_import.name}"
      end
    end
  ## log Nexpose API errors and move on
  rescue Nexpose::APIError => e
    ## if you hit ctrl+c, exit instead of resuming
    if e.to_s.include? "Received a user interrupt"
      log.warn "Exit requested by user"
      exit(0)
    end
    log.error "#{e.message} in site #{site_import.name}"
  end
end

