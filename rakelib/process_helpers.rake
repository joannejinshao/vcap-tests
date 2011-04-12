# Helper methods for handling at_exit hooks and killing/checking processes.
module ProcessHelper
  module_function
  # TODO - Silence output?
  def launch_nats(uri)
    unless tcp_port_open?(uri.port)
      log = File.join(BuildConfig.log_dir, 'nats.log')
      err = File.join(BuildConfig.log_dir, 'nats-errors.log')
      nats_cmd = "nats-server -p #{uri.port} -P #{BuildConfig.nats_pid} -D -l #{log} -d 2> #{err}"
      system "bundle exec #{nats_cmd} > /dev/null"
      wait_for_port(uri.port)
    end
  end

  def terminate_nats(uri)
    terminate_service_on(uri.port, BuildConfig.nats_pid)
  end

  def terminate_service_on(port, pid_file)
    pid = nil
    kill_process_from_pidfile(pid_file)
    # By the time we get here, the port should be closed,
    # and the pid_file should be gone.
    if tcp_port_open?(port)
      pid = read_pid_from(pid_file)
      if pid && process_running?(pid)
        fail "Process #{pid} (#{pid_file}) just would not die, and port #{port} is still open!"
      elsif pid_file =~ /nats/
        # FIXME - Autostart is hell.
        puts "WARNING - NATS was already running on port #{port} but it was auto-started!"
      else
        # port is open, and it's not us!
        fail "Something other than #{pid_file} appears to own port #{port}!"
      end
    end
  end

  def process_running?(pid)
    `ps -o rss= -p #{pid}`.length > 0
  end

  def wait_for_port(port, timeout = 10)
    start = Time.now
    time_spent = 0.0
    while time_spent < timeout
      break if tcp_port_open?(port)
      sleep 0.2
      time_spent += Time.now - start
    end
  end

  def tcp_port_open?(port)
    open = false
    begin
      TCPSocket.new('127.0.0.1', port.to_i).close
      open = true
    rescue StandardError, SystemCallError
    end
    open
  end

  # If the second argument is false, we ignore errors.
  # Useful for at_exit hooks, where there's no point raising an exception.
  # If the third argument is passed, it is the grace period
  # before we send the KILL signal.
  def kill_process_from_pidfile(file, strict = true, grace_period = 1)
    if File.exist?(file)
      if pid = read_pid_from(file)
        # Make sure the process is dead, then remove the pid_file
        die_die_die(pid, file, grace_period)
        # callers expect this helper to block, so we sleep until the timeout
        # has elapsed.
        sleep grace_period
      elsif strict
        # couldn't read pidfile; race or bad contents?
        fail "pidfile #{pid_file} existed but could not be read"
      end
    end
  end

  def remove_pid(pid_file)
    what = File.basename(pid_file, '.pid')
    puts "STOPPED: #{what}"
    FileUtils.rm_f(pid_file)
  end

  def read_pid_from(pid_file)
    pid = File.read(pid_file).chomp.to_i
    unless pid == 0
      pid
    end
  rescue StandardError, SystemCallError
  end

  def die_die_die(pid, pid_file, grace_period = 5)
    Process.kill('TERM', pid)
    killer = fork do
      sleep(grace_period)
      begin
        Process.kill('KILL', pid)
      rescue Errno::ECHILD, Errno::ESRCH
      ensure
        remove_pid(pid_file)
      end
    end
    Process.detach(killer)
    Process.waitpid(pid)
  rescue Errno::ECHILD, Errno::ESRCH
    # The subprocess that sends KILL will handle cleanup
  rescue => ex
    $stderr.puts "WARN: Unable to kill process #{pid}: #{ex.class} - #{ex}"
  end

  def remember_to_kill(*pid_files)
    at_exit do
      unless $clean_shutdown
        pid_files.each do |pid_file|
          # Proceed straight to KILL signals if anything is still running.
          ::ProcessHelper.kill_process_from_pidfile(pid_file, false, 0)
        end
      end
    end
  end

  def remember_to_kill_nats(uri, pid_file)
    at_exit do
      unless $clean_shutdown
        ::ProcessHelper.terminate_service_on(uri.port, pid_file)
      end
    end
  end

  # If there are any redis-server processes owned by us, and they
  # contain the given string somewhere in their args, kill them.
  def terminate_redis_servers(containing_string)
    lines = `ps -o pid=,command=`.chomp.split("\n")
    pids = []
    lines.each do |line|
      next unless line.include?('redis-server')
      next unless line.include?(containing_string)
      pid, comm = line.split(' ', 2)
      pids.push(pid)
    end
    if pids.any?
      system "kill -s TERM #{pids.join(' ')}"
      sleep 2
    end
  end
end

module StatusHelper
  require 'json' unless defined?(JSON)
  require 'net/http' unless defined?(Net::HTTP)

  def cloud_controller_ready?
    host = BuildConfig.controller_host
    path = '/info'
    begin
      client = Net::HTTP.new(host)
      headers, body = client.get(path)
      if headers.code == '200'
        info = JSON.parse(body)
        info.key?('name')
      end
    rescue Exception => ex
      $stderr.puts "#{ex.class}:#{ex}"
    end
  end
end

