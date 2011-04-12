namespace :ci do
  desc "Generate configuration files for core components"
  task :configure => [:activate_bundle, :create_working_directories] do
    $clean_shutdown = true
    profile = ENV['VCAP_BVT_PROFILE'] || 'acdev'
    @pidfiles, @service_pidfiles = *BuildConfig.generate(profile)

    puts "Configured VCAP using profile: #{profile}"
  end

  desc "Start the currently-configured CI system"
  task :start => [:configure, :start_nats, :start_components,
                  :sleep_until_ready, :start_services]

  # This task never executes if something raises an exception.
  # We have at_exit hooks to take care of that.
  desc "Stop the currently-configured CI system"
  task :stop => [:configure, :stop_services, :stop_components, :stop_nats] do
    $clean_shutdown = true
    Rake::Task['ci:succeed_or_fail'].invoke
  end

  desc "Using the generated configuration files, remove any existing data"
  task :reset => [:configure, :purge_db]

  # Does nothing if not running a test suite.
  # Otherwise, determines whether we should fail or pass.
  task :succeed_or_fail do
    job_name = $ci_job_name || "BVT"
    if $ci_exit_code && $ci_exit_code != 0
      fail "#{job_name} did not complete successfully - exited with code: #{$ci_exit_code.exitstatus}"
    elsif $ci_exit_code
      puts "#{job_name} completed successfully"
    end
  end

  # Called by CI tasks to indicate that they want automatic teardown at exit.
  task :starting_build do
    $stdout.sync = true
    $stderr.sync = true
    $clean_shutdown = false
    nats_uri = URI.parse(BuildConfig.nats_uri)
    # at_exit, force-stop components in reverse order.
    ProcessHelper.remember_to_kill_nats(nats_uri, BuildConfig.nats_pid)
    ProcessHelper.remember_to_kill(*@pidfiles.reverse)
    ProcessHelper.remember_to_kill(*@service_pidfiles.reverse)

    # Make sure a previous run didn't leave any redis servers running.
    ProcessHelper.terminate_redis_servers(BuildConfig.working_dir)

    # Fail quickly if any core components are still running, but not managed by us.
    router_pid = BuildConfig.fetch_option('router', 'pid')
    ProcessHelper.terminate_service_on(BuildConfig.router_port, router_pid)
    dea_pid    = BuildConfig.fetch_option('dea', 'pid')
    ProcessHelper.terminate_service_on(BuildConfig.dea_filer_port, dea_pid)
    cc_pid     = BuildConfig.fetch_option('cloud_controller', 'pid')
    ProcessHelper.terminate_service_on(BuildConfig.controller_port, cc_pid)
  end

  task :activate_bundle do
    require 'bundler'
    Bundler.setup
  end

  task :hacky_startup_delay do
    check = "ps -o command=|grep ruby|grep ci-working|grep -v grep"
    output = `#{check}`.strip
    unless output.empty?
      puts "Sleeping for 10 seconds while previous builds complete"
      sleep 10
      output = `#{check}`.strip
      unless output.empty?
        puts "Aborting; is previous build hung?"
        fail "Still running: #{output}"
      end
    end
  end

  # TODO - Run a script that makes judicious TRUNCATE requests instead.
  task :purge_db do
    db_log      = File.join(BuildConfig.log_dir, 'db_reset.log')
    db_err      = File.join(BuildConfig.log_dir, 'db_warn.log')
    config_file = File.join(BuildConfig.config_dir, 'cloud_controller.yml')
    cc_dir      = File.join(CoreComponents.root, 'cloud_controller')
    steps = ["unset BUNDLE_GEMFILE",
             "export CLOUD_CONTROLLER_CONFIG=#{config_file}",
             "export RAILS_ENV=production",
             "cd #{cc_dir}", "rake --silent db:migrate:reset > #{db_log} 2> #{db_err}"]
    system steps.join('; ')
    puts "CloudController database reset"
  end

  # Notably, this does not create the working directories specific services.
  # BuildTemplate handles that for us, so we don't need to repeat the
  # list of built-in services here.
  task :create_working_directories do
    subdirs = %w[run local/dea shared/droplets shared/resources config manifests services tmp]
    subdirs.each do |path|
      dir = File.join(BuildConfig.working_dir, path)
      FileUtils.mkdir_p(dir)
    end
    # creates ci-artifacts-dir if it doesn't already exist
    FileUtils.mkdir_p(BuildConfig.test_result_dir)
    FileUtils.mkdir_p(BuildConfig.log_dir)
  end

  # We start NATS separately to make sure nothing beats us to it.
  task :start_nats do
    %x{killall -INT nats-server 2>&1}
    uri = URI.parse(BuildConfig.nats_uri)
    ProcessHelper.launch_nats(uri)
    puts "NATS started on #{uri}"
  end

  task :stop_nats do
    uri = URI.parse(BuildConfig.nats_uri)
    ProcessHelper.terminate_nats(uri)
    puts "NATS stopped on #{uri}"
  end

  task :start_components do
    pid = fork do
      Bundler.with_clean_env do
        exec(BuildConfig.startup_script)
      end
    end
    Process.waitpid(pid)
    puts "Launching VCAP components"
  end

  task :stop_components do
    puts "Stopping VCAP components"
    if @pidfiles
      @pidfiles.each do |f|
        # Don't raise an error if we failed to read the pidfile.
        # Wait three seconds before sending KILL.
        ProcessHelper.kill_process_from_pidfile(f, false, 3)
      end
    end
  end

  task :start_services do
    pid = fork do
      Bundler.with_clean_env do
        exec(BuildConfig.service_startup_script)
      end
    end
    Process.detach(pid)
    puts "Launching VCAP services"
    sleep 5 # Give things a chance to register themselves.
  end

  task :stop_services do
    puts "Stopping VCAP services"
    if @service_pidfiles
      @service_pidfiles.each do |f|
        # Don't raise an error if we failed to read the pidfile.
        # Wait three seconds before sending KILL.
        ProcessHelper.kill_process_from_pidfile(f, false, 3)
      end
    end
    # Make sure we aren't the previous run somebody else is angry at.
    ProcessHelper.terminate_redis_servers(BuildConfig.working_dir)
  end

  # Block until the cloud is ready. Fail if it never happens.
  task :sleep_until_ready do
    puts "Waiting for VCAP to become ready"
    include StatusHelper
    started_at = Time.now
    time_spent = 0.0
    until cloud_controller_ready?
      time_spent += Time.now - started_at
      if time_spent >= BuildConfig.startup_timeout
        fail "Timed out after #{BuildConfig.startup_timeout} seconds waiting for startup"
      end
      sleep 1
    end
  end

  task :version_check do
    unless defined?(BasicObject)
      version = "#{RUBY_VERSION}p#{RUBY_PATCHLEVEL}"
      fail "CI tests launch components that use Fibers. Your ruby version is #{version}."
    end
  end
end
