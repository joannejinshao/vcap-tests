
require 'digest/sha1'
require 'fileutils'
require 'tempfile'
require 'tmpdir'
require 'pp'

# self contained
$:.unshift File.expand_path('../../vendor/gems/json/lib', __FILE__)
$:.unshift File.expand_path('../../vendor/gems/highline/lib', __FILE__)
$:.unshift File.expand_path('../../vendor/gems/httpclient/lib', __FILE__)
$:.unshift File.expand_path('../../vendor/gems/rubyzip2/lib', __FILE__)

require 'json/pure'
require 'highline/import'
require 'httpclient'
require 'zip/zipfilesystem'

require 'vmc_base'

module VMC; end

class VMC::Client < VMC::BaseClient

  VERSION = 0.998

  attr_reader :host, :base_uri, :droplets_uri, :services_uri, :resources_uri, :token, :args

  @@commands =  %w(version login logout register help services apps list push delete stop start update restart bounce)
  @@commands += %w(map unmap instances files target crashes stats info user passwd)

  def setup_target_uris
    get_host_target
    @base_uri = "http://#{@host}"
    @droplets_uri = "#{base_uri}/apps"
    @services_uri = "#{base_uri}/services"
    @resources_uri = "#{base_uri}/resources"
  end

  def check_target
    get_token # Just load it if its around
    @check = HTTPClient.get "#{base_uri}/info", nil, auth_hdr
    error "\nERROR: Unable to contact target server: [#{@base_uri}]\n\n" if @check.status != 200
    display "\n[#{@base_uri}]\n\n"
    check_puser if @puser
  rescue
    error "\nERROR: Unable to contact target server: [#{@base_uri}]\n\n"
  end

  def check_puser
    info_json = JSON.parse(@check.content)
    username = info_json['user']
    error "ERROR: Proxying to #{@puser} failed." unless (username && (username.downcase == @puser.downcase))
  end

  def run(argv)
    trap("TERM") { print "\nInterupted\n\n"; exit}
    trap("INT")  { print "\nInterupted\n\n"; exit}

    @args = argv

    # Quick test for common flags for help and version
    help if (get_option('-h') || get_option('-help'))
    version if (get_option('-v') || get_option('-version'))

    @puser = get_option('-u')

    verb = args.shift
    verb.downcase if verb
    if @@commands.include?(verb)
      setup_target_uris
      # Check to make sure the server is there..
      check_target unless verb =~ /target/i
      self.send(verb)
      display ""
    else
      error "\nUsage: vmc COMMAND [OPTIONS], Try 'vmc -help' for more information."
    end
  end

  def version
    puts "#{VERSION}"
    exit
  end

  def register
    puts "Register your account with an email account and password."
    email = ask("Email: ")
    password = ask("Password: ") {|q| q.echo = '*'}
    password2 = ask("Verify Password: ") {|q| q.echo = '*'}
    error "Passwords did not match, try again" if password != password2
    get_token # Just load it if its around
    register_internal(@base_uri, email, password, auth_hdr)
    display "Registration completed"
    # do an autologin also to setup token, avoiding login on next vmc command.
    login_save_token(email, password) unless @token
  rescue => e
    error "Problem registering, #{e}"
  end

  def login_save_token(email, password)
    # TODO: We should be url encoding email
    @token = login_internal(@base_uri, email, password)
    write_token
  end

  def login
    tries = 0
    begin
      email = ask("Email: ")
      password = ask("Password: ") {|q| q.echo = '*'}
      login_save_token(email, password)
      display ""
    rescue => e
      display "Problem with login, #{e}, try again or register for an account."
      retry if (tries += 1) < 3
    end
  end

  def logout
    FileUtils.rm_f(token_file)
    display "Succesfully logged out."
  end

  def target_file
    "#{ENV['HOME']}/.vmc_target"
  end

  def get_host_target
    return if @host
    if File.exists? target_file
      @host = File.read(target_file).strip!
      ha = @host.split('.')
      ha.shift
      @suggest_url = ha.join('.')
      @suggest_url = 'vcap.me' if @suggest_url.empty?
    else
      @host = 'localhost:8080'
      @suggest_url = 'vcap.me'
    end
  end

  def write_host_target(target_host)
    File.open(target_file, 'w+') { |f| f.puts target_host }
    FileUtils.chmod 0600, target_file
  end

  def token_file
    "#{ENV['HOME']}/.vmc_token"
  end

  def instance_file
    "#{ENV['HOME']}/.vmc_instances"
  end

  def get_token
    return @token if @token
    @token = File.read(token_file).strip! if File.exists?(token_file)
  end

  def check_for_token
    return if get_token
    display "Please Login:\n\n"
    login
    check_for_token
  end

  def write_token
    File.open(token_file, 'w+') { |f| f.puts @token }
    FileUtils.chmod 0600, token_file
  end

  def auth_hdr
    auth = { 'AUTHORIZATION' => "#{@token}" }
    auth['PROXY-USER'] = @puser if @puser
    return auth
  end

  def display_services_banner
    display "#{'Name'.ljust(15)} #{'Service'.ljust(10)} #{'Vendor'.ljust(10)} #{'Version'.ljust(10)} #{'Tiers'}"
    display "#{'----'.ljust(15)} #{'-------'.ljust(10)} #{'------'.ljust(10)} #{'-------'.ljust(10)} #{'-----'}"
  end

  def list_services(service_names, banner)
    services = []
    service_names.each { |service_name|
      sn = URI.escape("#{services_uri}/#{service_name}")
      response = HTTPClient.get(sn, nil, auth_hdr)
      error "Problem getting services list" if response.status != 200
      services << JSON.parse(response.content)
    }

    error "No services provisioned." if services.empty?

    display(banner)

    display_services_banner
    services.each { |h|
      display "#{h['name'].to_s.ljust(15)} ", false
      display "#{h['type'].ljust(10)} ", false
      display "#{h['vendor'].ljust(10)} ", false
      display "#{h['version'].ljust(10)} ", false
      display "#{h['tier']}"
    }
  end

  def app_list_services
    appname = (args.shift if args)
    error "Application name required\nvmc app services <appname>" unless appname

    response = HTTPClient.get "#{droplets_uri}/#{appname}", nil, auth_hdr
    error "Application does not exist." if response.status == 404
    service_names = JSON.parse(response.content)['services']
    error "Problem getting services list" if response.status != 200
    list_services(service_names, "Services consumed by Application '#{appname}':")
  end

  def user_list_services_helper
    service_names = get_user_service_names
    list_services(service_names, "All Provisioned Services:")
  end

  def get_user_service_names
    service_names = []
    response = HTTPClient.get "#{services_uri}", nil, auth_hdr
    response_json = JSON.parse(response.content)
    response_json.each { |service_desc| service_names << service_desc['name'] }
    service_names
  end

  def services
    check_for_token

    first_arg = (args.shift if args)

    case first_arg
      when "list" then user_list_services_helper
      when nil then user_list_services_helper
      when "add" then user_add_service_helper("service")
      when "remove" then user_remove_service_helper
      else display "Incorrect option #{first_arg}. Must be either 'list' (default), 'add', or 'remove'"
    end
  end

  def user_add_service_helper(service_name_prefix, service_type=nil, service_vendor=nil, service_version=nil, service_tier=nil)
    service_type = (args.shift if args) unless service_type
    service_vendor = (args.shift if args) unless service_vendor
    service_version = (args.shift if args) unless service_version
    service_tier = (args.shift if args) unless service_tier

    response = HTTPClient.get "#{base_uri}/info/services", nil, auth_hdr
    error "Problem getting services list" if response.status != 200

    last_print = :none

    services = JSON.parse(response.content)

    unless service_type
      choose do |menu|
        menu.header = "The following service types are available"
        menu.prompt = 'Please select one you wish to provision: '
        menu.select_by = :index

        services.each_key do |key|
          menu.choice(key) { service_type = key }
        end
      end
      last_print = :menu
    end
    error "Could not find service type '#{service_type}'." unless services[service_type]

    service_type_hash = services[service_type]
    unless service_vendor
      puts "" if last_print == :menu
      if service_type_hash.length == 1
        service_vendor = service_type_hash.first[0]
        say("Single vendor available: #{service_vendor}")
        last_print = :auto
      else
        puts "" if last_print == :auto
        choose do |menu|
          menu.header = "The following #{service_type} vendors are available"
          menu.prompt = 'Please select one you wish to provision: '
          menu.select_by = :index

          service_type_hash.each_key do |key|
            menu.choice(key) { service_vendor = key }
          end
        end
       last_print = :menu
      end
    end
    error "Could not find vendor '#{service_vendor}' for #{service_type} services." unless service_type_hash[service_vendor]

    service_vendor_hash = service_type_hash[service_vendor]
    unless service_version
      puts "" if last_print == :menu
      if service_vendor_hash.length == 1
        service_version = service_vendor_hash.first[0]
        say("Single version available: #{service_version}")
        last_print = :auto
      else
        puts "" if last_print == :auto
        choose do |menu|
          menu.header = "The following #{service_vendor} #{service_type} versions are available"
          menu.prompt = 'Please select one you wish to provision: '
          menu.select_by = :index

          service_vendor_hash.each_key do |key|
            menu.choice(key) { service_version = key }
          end
        end
       last_print = :menu
      end
    end
    error "Could not find version '#{service_version}' for #{service_vendor} #{service_type}." unless service_vendor_hash[service_version]

    service_version_hash = service_vendor_hash[service_version]
    unless service_tier
      puts "" if last_print == :menu

      tiers = []
      service_version_hash['tiers'].each {|k,v| tiers << [k, v]}
      tiers = tiers.sort do |a, b|
        (a[1]['order'] || 0) - (b[1]['order'] || 0)
      end

      if tiers.length == 1
        service_tier = tiers.first
        say("Single tier available: #{service_tier} - #{service_version_hash['tiers'][service_tier][:description]}")
        last_print = :auto
      else
        puts "" if last_print == :auto
        choose do |menu|
          menu.header = "The following #{service_vendor} #{service_type} tiers are available"
          menu.prompt = 'Please select one you wish to provision: '
          menu.select_by = :index

          tiers.each do |key|
            menu.choice("#{key[0]} (#{service_version_hash['tiers'][key[0]]['description']})") { service_tier = key[0] }
          end
        end
        last_print = :menu
      end
    end
    error "Could not find tier '#{service_tier}' for #{service_vendor} #{service_type}." unless service_version_hash['tiers'][service_tier]

    service_tier_hash = service_version_hash['tiers'][service_tier]
    options = service_tier_hash['options']
    pricing = service_tier_hash['pricing']

    option_values = {}
    if options
      options.each do |k, v|
        puts "" if last_print == :menu
        if v['type'] == 'value'
          puts "" if last_print == :auto
          choose do |menu|
            menu.prompt = "#{k} (#{v['description']}): "
            menu.select_by = :index

            if pricing
              price_type = pricing['type']
              price_period = pricing['period']
              prices = pricing['values']
            end

            v['values'].each do |option|
              option_value = option
              option = "#{option} (#{format_price(prices[option], price_type, price_period)})" if price_type
              menu.choice("#{option}") { option_values[k] = option_value }
            end
          end
          last_print = :menu
        end
      end
    end
    # FIXME: We need a better name creation logic that checks for existing services
    default_service_name = "#{service_name_prefix}_#{service_type}"
    service_name = ask("Specify the name of the service [#{default_service_name}]: ")
    service_name = default_service_name if service_name.empty?

    services = {
      :name => service_name,
      :type => service_type,
      :vendor => service_vendor,
      :tier => service_tier,
      :version => service_version,
      :options => option_values
    }

    check_for_token
    response = add_service_internal @services_uri, services, auth_hdr
    error "Problem provisioning services" if response.status >= 400
    display "Service '#{service_vendor}' provisioned."

    service_name
  end

  def user_remove_service_helper
    service_name = (args.shift if args)
    error "Service name required\nvmc service remove <service-name>" unless service_name

    remove_service_internal(services_uri, service_name, auth_hdr)
  end

  def app_add_service
    appname = (args.shift if args)
    service_type = (args.shift if args)
    service_vendor = (args.shift if args)
    service_version = (args.shift if args)
    service_tier = (args.shift if args)

    error "Application name required\nvmc apps add-service <appname> [service] [vendor] [version] [tier]" unless appname

    app_add_service_helper(appname, service_type, service_vendor, service_version, service_tier)

    @appname = appname
    restart
  end

  def app_add_service_helper(appname, service_type=nil, service_vendor=nil, service_version=nil, service_tier=nil)
    check_for_token

    # If we have a single arg, let's assume its a service name..
    if service_type && !service_vendor && !service_version && !service_tier
      service_name = service_type
      service_type = nil
    end

    service_names = get_user_service_names
    if service_name && (service_names.empty? || !service_names.include?(service_name))
      display "Incorrect service name"
      service_name = nil
    end

    if !service_names.empty? && !service_name
      list_services(get_user_service_names, "The following services have been provisioned for you:")
      use_existing = ask "Will you like to use one of these (y/n)? "
      if use_existing.upcase == 'Y'
        begin
          service_name = ask "Which service (name)? "
          if !service_names.include?(service_name)
            display "Incorrect service name, please type again"
            service_name = nil
          end
        end while !service_name
      end
    end

    if !service_name
      display "Let's provision a new service"
      service_name = user_add_service_helper(appname, service_type, service_vendor, service_version, service_tier)
    end

    display "Creating new service binding to '#{service_name}' for '#{appname}'."

    # Now get the app and update it with the provisioned service
    response = get_app_internal(droplets_uri, appname, auth_hdr)
    appinfo = JSON.parse(response.content)
    provisioned_service = appinfo['services']
    provisioned_service = [] unless provisioned_service
    provisioned_service << service_name
    appinfo['services'] = provisioned_service
    response = update_app_state_internal droplets_uri, appname, appinfo, auth_hdr
    error "Problem updating application with new services" if response.status >= 400
    display "Application '#{appname}' updated."
  end

  def format_price(amount, type, *rest)
    case type
    when 'flat'
      return "$#{amount}/#{rest[0]}"
    when 'metered'
      raise "Not Implemented"
    end
  end

  # Not DRY, FIXME
  def app_remove_service
    appname = (args.shift if args)
    service_name = (args.shift if args)

    unless (appname && service_name)
      error "Application name and ServiceID are required.\nvmc apps remove_service <appname> <service>"
    end

    check_for_token

    app_response = get_app_internal(droplets_uri, appname, auth_hdr)
    appinfo = JSON.parse(app_response.content)
    provisioned_service = appinfo['services']
    provisioned_service = [] unless provisioned_service
    provisioned_service.delete(service_name)
    appinfo['services'] = provisioned_service
    response = update_app_state_internal droplets_uri, appname, appinfo, auth_hdr
    error "Problem updating application with new services" if response.status >= 400
    display "Application '#{appname}' updated"
    display "Service #{service_name} removed."
    @appname = appname
    restart
  end

  def list
    apps
  end

  def apps
    check_for_token
    first_arg = (args.shift if args)

    case first_arg
      when "list" then list_apps
      when nil then list_apps
      when 'add-service' then app_add_service
      when 'remove-service' then app_remove_service
      when 'services' then app_list_services
      else "Incorrect option #{first_arg}. Must be 'list' (default), 'services', 'add-service', or 'remove-service"
    end
  end

  def list_apps
    droplets_full = get_apps_internal @droplets_uri, auth_hdr
    if droplets_full.empty?
      display "No applications available."
      return
    end
    display "#{'APPNAME'.ljust 15} #{'HEALTH'.ljust 10} #{'INSTANCES'.ljust 10} URL\n"
    display "#{'-------'.ljust 15} #{'-----'.ljust 10} #{'---------'.ljust 10} ---\n"
    droplets_full.each { |d|

      healthy_instances = d['runningInstances']
      expected_instance = d['instances']
      health = nil

      if d['state'] == "STARTED" && expected_instance > 0 && healthy_instances
        health = format("%.3f", healthy_instances.to_f / expected_instance).to_f
      end

      if health
        if health == 1.0
          health = "RUNNING"
        else
          health = "#{(health * 100).round}%"
        end
      else
        if d['state'] == 'STOPPED'
          health = 'STOPPED'
        else
          health = 'N/A'
        end
      end

      display "#{d['name'].ljust 15} ", false
      display "#{health.ljust 10} ", false
      display "#{d['instances'].to_s.ljust 10} ", false
      display "#{d['uris'].join(', ')}"
    }
  rescue => e
    error "Problem executing command, #{e}"
  end

  def push
    instances = get_option('--instances') || 1
    @startup_command = get_option('--exec') || 'thin start'
    ignore_framework = get_option('--ignore_framework') || get_option('--noframework')

    if args
      appname = args.shift
      url = args.shift
    end

    unless appname && url
      proceed = ask("Would you like to deploy from the current directory? [Yn]: ")
      error "Push aborted" if proceed == 'n' || proceed == 'N'
      appname = ask("Application Name: ") unless appname
      error "Push aborted: Application Name required." if appname.empty?
      url = ask("Application Deployed URL: '#{appname}.#{@suggest_url}'? ") unless url
      url = "#{appname}.#{@suggest_url}" if url.empty?
    end

    check_for_token
    response = get_app_internal(@droplets_uri, appname, auth_hdr)
    error "Access Denied, please login or register" if response.status == 403
    error "Application #{appname} already exists, use update or delete." if response.status == 200

    # Run the framework detection process or set to defaults, depending on the presence of the 'ignore_framework' option
    detect_framework(ignore_framework)

    choose do |menu|
      menu.layout = :one_line
      menu.prompt = "Memory Reservation [Default:#{@reserved_memory}] "
      menu.default = @reserved_memory
      mem_choices.each { |choice| menu.choice(choice) {  @reserved_memory = choice } }
    end

    # Set to MB number
    mem_quota = mem_choice_to_quota(@reserved_memory)

    manifest = {
      :name => "#{appname}",
      :staging => {
        :model => @framework,
        :stack => @startup_command
      },
      :uris => [url],
      :instances => instances,
      :resources => {
        :memory => mem_quota
      },
    }

    display "Uploading Application Information."

    # Send the manifest to the cloud controller
    response = create_app_internal(@droplets_uri, manifest, auth_hdr)
    error "Error creating application: #{JSON.parse(response.content)['description']}" if response.status == 400

    # Provision database here if needed.
    if framework_needs_db?(@framework)
      proceed = ask("This framework usually needs a database, would you like to provision it? [Yn]: ")
      if proceed != 'n' && proceed != 'N'
        app_add_service_helper(appname, 'database')
        provisioned_db = true
      end
    end

    # Stage and upload the app bits.
    display "Uploading Application."
    upload_size = upload_app_bits(@resources_uri, @droplets_uri, appname, auth_hdr, @detected_war_file, provisioned_db)
    if upload_size > 1024*1024
      upload_size  = (upload_size/(1024.0*1024.0)).round.to_s + 'M'
    elsif upload_size > 0
      upload_size  = (upload_size/1024.0).round.to_s + 'K'
    end
    display "\nUploaded Application '#{appname}' (#{upload_size})."

    display "Push completed."

    @appname = appname
    display "Starting application '#{appname}'"
    start
  rescue => e
    error "Problem executing command, #{e}"
  end

  def delete
    appname = (args.shift if args)
    error "Application name required, vmc delete <appname || --all>." unless appname

    check_for_token

    # wildcard behavior
    apps = []
    if appname == '--all'
      droplets_full = get_apps_internal @droplets_uri, auth_hdr
      apps = droplets_full.collect { |d| "#{d['name']}" }
      apps.each { |app| delete_app(app) }
    else
      delete_app(appname)
    end
  rescue => e
    error "Problem executing command, #{e}"
  end

  def delete_app(appname)
      response = get_app_internal @droplets_uri, appname, auth_hdr
      if response.status != 200
        display "Application '#{appname}' does not exist."
        return
      end
      appinfo = JSON.parse(response.content)
      services_to_delete = []
      app_services = appinfo['services']
      app_services.each { |service|
        del_service = ask("Application '#{appname}' uses '#{service}' service, would you like to delete it? [yN]: ")
        services_to_delete << service if (del_service == 'y' || del_service == 'Y')
      }
      delete_app_internal @droplets_uri, appname, services_to_delete, auth_hdr
      display "Application '#{appname}' deleted."
  end

  # Detect the appropriate framework. Sets @framework, @reserved_memory, @startup_command and @detected_war_file
  # as needed.
  def detect_framework(ignore = false)
    # TODO - Not dry, refactor these defaults out, and smoke out why sometimes they are deliberately
    # not set during framework detection.
    framework, mem, exec = 'http://b20nine.com/unknown', '256M', nil
    if ignore
     @framework = framework
     @reserved_memory = mem
     @detected_war_file = nil
     return
    end

    # FIXME - The Rails 2 vs. Rails 3 vs. Rack detection is definitely wrong
    if File.exist?('config/environment.rb')
      display "Rails application detected."
      framework = "rails/1.0"
    elsif Dir.glob('*.war').first
      opt_war_file = Dir.glob('*.war').first
      display "Java war file found, detecting framework..."

      entries = []
      Zip::ZipFile.foreach(opt_war_file) { |zentry| entries << zentry }
      @detected_war_file = opt_war_file
      # TODO - Use .grep here instead of joining and then =~ing
      contents = entries.join("\n")

      if contents =~ /WEB-INF\/grails-app/
        display "Grails application detected."
        framework = "grails/1.0"
        mem = '512M'
      elsif contents =~ /WEB-INF\/classes\/org\/springframework/
        display "SpringSource application detected."
        framework = "spring_web/1.0"
        mem = '512M'
      elsif contents =~ /WEB-INF\/lib\/spring-core.*\.jar/
        display "SpringSource application detected."
        framework = "spring_web/1.0"
        mem = '512M'
      else
        display "Unknown J2EE Web Application"
        framework = "spring_web/1.0"
      end
    elsif File.exist?('web.config')
      display "ASP.NET application detected."
      framework = "asp_web/1.0"
    elsif !Dir.glob('*.rb').empty?
      matched_file = nil
      Dir.glob('*.rb').each do |fname|
        next if matched_file
        File.open(fname, 'r') do |f|
          str = f.read # This might want to be limited
          matched_file = fname if (str && str.match(/^\s*require\s*'sinatra'/i))
        end
      end
      if matched_file && !File.exist?('config.ru')
        display "Simple Sinatra application detected in #{matched_file}."
        exec = "ruby #{matched_file}"
      end
      mem = '128M'
    elsif !Dir.glob('*.js').empty?
      # Fixme, make other files work too..
      if File.exist?('app.js')
        display "Node.js application detected."
        framework = "nodejs/1.0"
        mem = '64M'
      end
    end
    @framework = framework
    @reserved_memory = mem
    @startup_command = exec if exec
  end

  def stop
    appname = @appname || (args.shift if args)
    error "Application name required, vmc stop <appname>." unless appname

    check_for_token
    response = get_app_internal @droplets_uri, appname, auth_hdr
    if response.status != 200
      display "Application '#{appname}' does not exist, use push first."
      return
    end
    appinfo = JSON.parse(response.content)
    appinfo['state'] = 'STOPPED'
    #display JSON.pretty_generate(appinfo)

    hdrs = auth_hdr.merge({'content-type' => 'application/json'})
    update_app_state_internal @droplets_uri, appname, appinfo, auth_hdr
    display "Application '#{appname}' stopped."
  rescue => e
    error "Problem executing command, #{e}"
  end

  def start
    appname = @appname || (args.shift if args)
    error "Application name required, vmc start <appname>." unless appname

    check_for_token
    response = get_app_internal @droplets_uri, appname, auth_hdr
    if response.status != 200
      display"Application #{appname} does not exist, use push first."
      return
    end
    appinfo = JSON.parse(response.content)
    if (appinfo['state'] == 'STARTED')
      display "Application '#{appname}' is already running."
      return
    end

    appinfo['state'] = 'STARTED'

    response = update_app_state_internal @droplets_uri, appname, appinfo, auth_hdr
    raise "Problem starting application #{appname}." if response.status != 200
    display "Application '#{appname}' started."
  rescue => e
    error "Problem executing command, #{e}"
  end

  def bounce
    restart
  end

  def restart
    @appname = (args.shift if args) unless @appname
    stop
    start
  rescue => e
    error "Problem executing command, #{e}"
  end

  def update
    appname = (args.shift if args)
    error "Application name required, vmc update <appname>." unless appname

    check_for_token

    response = get_app_internal @droplets_uri, appname, auth_hdr
    if response.status != 200
      display "Application '#{appname}' does not exist, use push first."
      return
    end
    appinfo = JSON.parse(response.content)

    display "Updating application '#{appname}'."

    mem = current_mem = mem_quota_to_choice(appinfo['resources']['memory'])
    choose do |menu|
      menu.layout = :one_line
      menu.prompt = "Update Memory Reservation? [Current:#{current_mem}] "
      menu.default = current_mem
      mem_choices.each { |choice| menu.choice(choice) {  mem = choice } }
    end

    if (mem != current_mem)
      appinfo['resources']['memory'] = mem_choice_to_quota(mem)
      response = update_app_state_internal @droplets_uri, appname, appinfo, auth_hdr
      raise "Problem updating memory reservation for #{appname}" if response.status != 200
      display "Updated memory reservation to '#{mem}'."
    end

    display "Uploading Application."
    upload_app_bits(@resources_uri, @droplets_uri, appname, auth_hdr, Dir.glob('*.war').first)

    if get_option('--nocanary')
      @appname = appname
      restart
      return
    end

    response = update_app_internal @droplets_uri, appname, auth_hdr

    raise "Problem updating application" if response.status != 200 && response.status != 204

    last_state = 'NONE'
    begin
      response = get_update_app_status @droplets_uri, appname, auth_hdr

      update_info = JSON.parse(response.content)
      update_state = update_info['state']
      if update_state != last_state
        display('') unless last_state == 'NONE'
        display("#{update_state.ljust(15)}", false)
      else
        display('.', false)
      end

      if update_state == 'SUCCEEDED' || update_state == 'CANARY_FAILED'
        display('')
        if update_state == 'CANARY_FAILED' && update_info['canary']
          begin
            map = File.open(instance_file, 'r') { |f| JSON.parse(f.read) }
          rescue
            map = {}
          end

          map["#{appname}-canary"] = update_info['canary']

          File.open(instance_file, 'w') {|f| f.write(map.to_json)}
          display("Debug the canary using 'vmc files #{appname} --instance #{appname}-canary'")
        end
        break
      else
        last_state = update_state
      end
      sleep(0.5)
    end while true

  rescue => e
    error "Problem executing command, #{e}"
  end

  def change_instances(appinfo, appname, instances)
    match = instances.match(/([+-])?\d+/)
    error "Invalid number of instances '#{instances}', vmc instances <appname> <num>." unless match

    instances = instances.to_i
    current_instances = appinfo['instances']
    new_instances = match.captures[0] ? current_instances + instances : instances
    error "There must be at least 1 instance." if new_instances < 1

    if current_instances == new_instances
      display "Application '#{appname}' is already running #{new_instances} instance#{'s' if new_instances > 1}."
      return
    end

    appinfo['instances'] = new_instances
    response = update_app_state_internal @droplets_uri, appname, appinfo, auth_hdr
    raise "Problem updating number of instances for #{appname}" if response.status != 200
    display "Scaled '#{appname}' #{new_instances > current_instances ? 'up' : 'down'} to " +
            "#{new_instances} instance#{'s' if new_instances > 1}."
  end

  def get_instances(appname)
    instances_info_envelope = get_app_instances_internal(@droplets_uri, appname, auth_hdr)

    # Empty array is returned if there are no instances running.
    error "No running instances for '#{appname}'" if instances_info_envelope.is_a?(Array)

    instances_info = instances_info_envelope['instances']
    display "#{'Index'.ljust 5} #{'State'.ljust 15} #{'Since'.ljust 20}\n"
    display "#{'--'.ljust 5} #{'--------'.ljust 15} #{'-------------'.ljust 20}\n"

    instances_info.each {|entry| entry[0] = entry[0].to_i}
    instances_info = instances_info.sort {|a,b| a['index'] - b['index']}
    instances_info.each do |entry|
      display "#{entry['index'].to_s.ljust 5} #{entry['state'].ljust 15} #{Time.at(entry['since']).strftime("%m/%d/%Y %I:%M%p").ljust 20}\n"
    end
  end

  def instances
    appname = @appname || (args.shift if args)
    error "Application name required, vmc instances <appname> [num | delta]." unless appname

    check_for_token
    response = get_app_internal @droplets_uri, appname, auth_hdr
    if response.status != 200
      display"Application #{appname} does not exist, use push first."
      return
    end
    appinfo = JSON.parse(response.content)

    instances = args.shift if args
    if instances
      change_instances(appinfo, appname, instances) if instances
    elsif
      get_instances(appname)
    end

  rescue => e
    error "Problem executing command, #{e}"
  end

  def crashes
    appname = @appname || (args.shift if args)
    error "Application name required, vmc crashes <appname>." unless appname

    check_for_token
    response = get_app_crashes_internal @droplets_uri, appname, auth_hdr
    if response.status == 404
      display"Application #{appname} does not exist, use push first."
      return
    elsif response.status != 200
      display"Could not fetch application crashes."
      return
    end
    crashes = JSON.parse(response.content)['crashes']
    instance_map = {}

    display "#{'Name'.ljust 10} #{'Id'.ljust 40} #{'Since'.ljust 20}\n"
    display "#{'--'.ljust 10} #{'--------'.ljust 40} #{'-------------'.ljust 20}\n"

    counter = 1

    crashes = crashes.to_a.sort {|a,b| a['since'] - b['since']}
    crashes.each do |crash|
      name = "#{appname}-#{counter}"
      display "#{name.ljust 10} #{crash['instance'].ljust 40} #{Time.at(crash['since']).strftime("%m/%d/%Y %I:%M%p").ljust 20}\n"
      instance_map[name] = crash['instance']
      counter +=1
    end

    File.open(instance_file, 'w') {|f| f.write(instance_map.to_json)}
  rescue => e
    error "Problem executing command, #{e}"
  end

  def map
    appname = (args.shift if args)
    url = (args.shift if args)

    error "Application name and url required, vmc map <appname> <url>." unless appname && url

    check_for_token
    response = get_app_internal @droplets_uri, appname, auth_hdr
    error "Application #{appname} does not exist, use push first." if response.status != 200

    appinfo = JSON.parse(response.content)

    appinfo['uris'] << url

    #display JSON.pretty_generate(appinfo)
    response = update_app_state_internal @droplets_uri, appname, appinfo, auth_hdr
    error "Error: #{JSON.parse(response.content)['description']}" if response.status == 400

    display "Map completed."
  rescue => e
    error "Problem executing command, #{e}"
  end

  def unmap
    appname = (args.shift if args)
    url = (args.shift if args)

    error "Application name and url required, vmc unmap <appname> <url>." unless appname && url

    check_for_token
    response = get_app_internal @droplets_uri, appname, auth_hdr
    if response.status != 200
      display"Application #{appname} does not exist, use push first."
      return
    end

    url = url.gsub(/^http(s*):\/\//i, '')
    appinfo = JSON.parse(response.content)

    if appinfo['uris'].delete(url) == nil
      error "You can only unmap a previously registered URL."
    end

    #display JSON.pretty_generate(appinfo)
    update_app_state_internal @droplets_uri, appname, appinfo, auth_hdr

    display "Unmap completed."
  rescue => e
    error "Problem executing command, #{e}"
  end

  # TODO - Fix getoption timings to allow for options anywhere etc like below.

  def files
    appname = (args.shift if args)
    error "Application name required, vmc files <appname> <pathinfo> [--instance <instance>]." unless appname
    check_for_token
    response = get_app_internal @droplets_uri, appname, auth_hdr
    if response.status != 200
      display"Application #{appname} does not exist, use push first."
      return
    end
    instance = get_option('--instance') || '0'

    begin
      map = File.open(instance_file) {|f| JSON.parse(f.read)}
      instance = map[instance] if map[instance]
    rescue
    end

    path = args.shift || '/'
    response = get_app_files_internal @droplets_uri, appname, instance, path, auth_hdr
    if response.status != 200 && response.status == 400
      error "Information not available, either pathinfo is incorrect or instance index is out of bounds."
    end
    display response.content
  rescue => e
    error "Problem executing command, #{e}"
  end

  # Get the current logged in user
  def user
    info_json = JSON.parse(@check.content)
    username = info_json['user'] || 'N/A'
    display "[#{username}]"
  end

  # Change the current users passwd
  def passwd
    check_for_token
    user_info = JSON.parse(@check.content)
    email = user_info['user']
    puts "Changing password for #{email}\n\n"
    password = ask("Password: ") {|q| q.echo = '*'}
    password2 = ask("Verify Password: ") {|q| q.echo = '*'}
    error "Passwords did not match, try again" if password != password2

    response = get_user_internal(@base_uri, email, auth_hdr)
    user_info = JSON.parse(response.content)
    user_info['password'] = password
    change_passwd_internal(@base_uri, user_info, auth_hdr)

    display "Password succesfully changed."
    # do an autologin also to setup token, avoiding login on next vmc command.
    # only if not proxying
    login_save_token(email, password) unless @puser
    rescue => e
      error "Problem changing password, #{e}"
  end

  # Define a new cloud controller target
  def target
    unless target_host = (args.shift if args)
      display "\n[#{@base_uri}]"
      return
    end

    target_host = target_host.gsub(/^http(s*):\/\//i, '')
    try_host = "http://#{target_host}/info"
    target_host_display = "http://#{target_host}"
    display ''
    begin
      response = HTTPClient.get try_host
      if response.status != 200
		    display response.content
        error "New Target host is not valid: '#{target_host_display}'"
      end
      response_json = JSON.parse(response.content)
      error "New Target host is not valid: '#{target_host_display}'" unless
        response_json['name'] && response_json['version'] && response_json['support'] && response_json['description']
    rescue => e
		  display e
      error "New Target host is not valid: '#{target_host_display}'"
    end
    write_host_target(target_host)
    display "Succesfully targeted to [#{target_host_display}]"
  end

  def display_services_directory_banner
    display "#{'Service'.ljust(10)} #{'Vendor'.ljust(10)} #{'Version'.ljust(20)} #{'Description'}"
    display "#{'-------'.ljust(10)} #{'------'.ljust(10)} #{'-------'.ljust(20)} #{'-----'}"
  end

  def info
    services = (args.shift if args)
    if services
      check_for_token
      response = HTTPClient.get "#{base_uri}/info/services", nil, auth_hdr
      display "Services Directory:\n\n"
      services = JSON.parse(response.content)
      display_services_directory_banner
      services.each { |service_type, value|
        value.each { |vendor, version|
          version.each { |version_str, service|
            display "#{service_type.ljust(10)} ", false
            display "#{vendor.ljust(10)} ", false
            display "#{version_str.ljust(20)} ", false
            display "#{service['description']}"
          }
        }
      }
    else
      info_json = JSON.parse(@check.content)
      display "#{info_json['name']}: #{info_json['description']}"
      display "For support visit #{info_json['support']}"
      display ""
      display "Target: #{@base_uri} (v#{info_json['version']})"
      display "User:   #{info_json['user']}" if info_json['user']
      display "Client: (v#{VERSION})"
    end
  end

  # Get stats for application
  def stats
    # TODO(dlc) DRY from above files command
    appname = (args.shift if args)
    error "Application name required, vmc stats <appname>." unless appname
    check_for_token
    response = get_app_internal @droplets_uri, appname, auth_hdr
    if response.status != 200
      display"Application #{appname} does not exist, use push first."
      return
    end
    response = get_app_stats_internal @droplets_uri, appname, auth_hdr
    if response.status != 200 && response.status == 400
      error "Information not available, is instance index out of bounds?"
    end

    display " #{'Instance '.ljust(10)} #{'Host:Port'.ljust(20)} #{'CPU (Cores)'.ljust(15)} #{'Memory (limit)'.ljust(15)} #{'Disk (limit)'.ljust(15)} #{'Uptime '.ljust(5)}"
    display " #{'---------'.ljust(10)} #{'---------'.ljust(20)} #{'-----------'.ljust(15)} #{'--------------'.ljust(15)} #{'------------'.ljust(15)} #{'------ '.ljust(5)}"

    stats = JSON.parse(response.content).to_a

    stats.each {|entry| entry[0] = entry[0].to_i}
    stats = stats.sort {|a,b| a[0] - b[0]}
    stats.each do |entry|
      index, index_entry = entry
      stat = index_entry['stats']
      next unless stat
      hp = "#{stat['host']}:#{stat['port']}"
      uptime = uptime_string(stat['uptime'])
      usage = stat['usage']
      if usage
        cpu   = usage['cpu']
        mem   = (usage['mem'] * 1024) # mem comes in K's
        disk  = usage['disk']
      end

      mem_quota = stat['mem_quota']
      disk_quota = stat['disk_quota']

      mem  = "#{pretty_size(mem)} (#{pretty_size(mem_quota, 0)})"
      disk = "#{pretty_size(disk)} (#{pretty_size(disk_quota, 0)})"
      cpu = cpu ? cpu.to_s : 'NA'
      cpu = "#{cpu}% (#{stat['cores']})"

      display " #{index.to_s.ljust(10)} #{hp.ljust(20)} #{cpu.ljust(15)} #{mem.ljust(15)} #{disk.ljust(15)} #{uptime.ljust(5)}"

    end

  rescue => e
    error "Problem executing command, #{e}"
  end


  ##################################################################
  # Non VMC Commands
  ##################################################################

  def framework_needs_db?(framework)
    return true if (framework == 'rails/1.0')
    return true if (framework == 'grails/1.0')
    return true if (framework == 'spring_web/1.0')
    return true if (framework == "asp_web/1.0")
    return false
  end

  def uptime_string(delta)
    num_seconds = delta.to_i
    days = num_seconds / (60 * 60 * 24);
    num_seconds -= days * (60 * 60 * 24);
    hours = num_seconds / (60 * 60);
    num_seconds -= hours * (60 * 60);
    minutes = num_seconds / 60;
    num_seconds -= minutes * 60;
    "#{days}d:#{hours}h:#{minutes}m:#{num_seconds}s"
  end

  def pretty_size(size, prec=1)
    return 'NA' unless size
    return "#{size}B" if size < 1024
    return sprintf("%.#{prec}fK", size/1024.0) if size < (1024*1024)
    return sprintf("%.#{prec}fM", size/(1024.0*1024.0)) if size < (1024*1024*1024)
    return sprintf("%.#{prec}fG", size/(1024.0*1024.0*1024.0))
  end

  def display(msg, nl=true)
    if nl
      puts(msg)
    else
      print(msg)
      STDOUT.flush
    end
  end

  def error(msg)
    STDERR.puts(msg)
    STDERR.puts('')
    exit 1
  end

  def mem_choices
    ['64M', '128M', '256M', '512M', '1G', '2G']
  end

  def mem_choice_to_quota(mem_choice)
    (mem_choice =~ /(\d+)M/i) ? mem_quota = $1.to_i : mem_quota = mem_choice.to_i * 1024
    mem_quota
  end

  def mem_quota_to_choice(mem)
    if mem < 1024
      mem_choice = "#{mem}M"
    else
      mem_choice = "#{(mem/1024).to_i}G"
    end
    mem_choice
  end

  def get_option(options, default=true)
    test = [options]
    return unless opt_index = args.select { |a| test.include? a }.first
    opt_position = args.index(opt_index) + 1
    if args.size > opt_position && opt_value = args[opt_position]
      if opt_value.include?('--')
        opt_value = nil
      else
        args.delete_at(opt_position)
      end
    end
    args.delete(opt_index)
    opt_value ||= default
  end

  def help
    usage = <<HLPTXT

 version, -v                                 # version
 help, -h                                    # show usage

 target              <host[:port]>           # sets the AppCloud target site
 info                [services]              # information (optionally about services)

 register                                    # register and create an account
 login                                       # login
 logout                                      # logout
 passwd                                      # change password for current user
 user                                        # display current user

 services                                    # list of services available
 services add        [service]               # provision a service
 services remove     <service>               # remove a provisioned service

 apps                                        # list your apps
 apps add-service    <appname>               # create a service binding for your application
 apps remove-service <appname>               # remove a service binding from your application
 apps services       <appname>               # list service bindings for your application
 list                                        # alias for apps

 push                <appname>               # push and start the application
 start               <appname>               # start the application
 stop                <appname>               # stop the application
 restart             <appname>               # restart the application
 bounce              <appname>               # alias for restart
 delete              <appname> [--all]       # delete the application
 update              <appname> [--nocanary]  # update the application
 instances           <appname> [num]         # list instances, scale up or down the number of instances
 map                 <appname> <url>         # register the application with the url
 unmap               <appname> <url>         # unregister the application from the url
 crashes             <appname>               # list recent application crashes
 files               <appname> <dir|file>    # directory listing or file download

 stats               <appname>               # report resource usage for the application


HLPTXT
    display usage
    exit
  end

end


