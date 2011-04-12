namespace :java_client do
  java_steps = ['bundler:install:production',
                'bundler:check',
                'ci:hacky_startup_delay',
                'ci:configure',
                'java_client:clone_repo',
                'ci:reset',
                'ci:starting_build',
                'ci:start',
                'java_client:run_for_ci',
                'ci:stop']
  task :ci_tests => java_steps

  # The 'starting_build' task triggers automatic shutdown of components.
  # This task expects 'clone_repo' to already have run, but doesn't depend
  # on it directly; if repo cloning fails, we don't want to bother
  # launching components, so we run it early in the process.
  task :run_for_ci do
    $ci_exit_code = nil
    $ci_job_name = "Java client tests"
    # Don't fail the Rake run if a test fails.
    # We still want to run our 'stop' task whenever possible.
    # ci:succeed_or_fail will run after everything has stopped.
    puts "Starting Java-client-driven tests"
    env_target = ENV['VCAP_BVT_TARGET'] || 'vcap.me'
    if env_target[0,3] == 'api'
      target = "http://#{env_target}"
    else
      target = "http://api.#{env_target}"
    end
    target_flag = "-Dvcap.target=#{target}"
    maven_cmd = "cd #{BuildConfig.java_client_dir}; mvn #{target_flag} -Dvcap.passwd=test-pass -e -ff clean test"
    `#{maven_cmd}`
    $ci_exit_code = $?.dup
  end

  task :clone_repo do
    checkout_dir = BuildConfig.java_temp_dir
    FileUtils.rm_rf(checkout_dir)
    FileUtils.mkdir_p(checkout_dir)
    puts "Cloning Java git repository"
    git_uri = "git@github.com:vmware-ac/java.git"
    git_cmd = "cd #{checkout_dir}; git clone #{git_uri}"
    output = `#{git_cmd}`
    code = $?.exitstatus
    if code == 0
      puts "Successfully cloned Java git repository"
    else
      fail "Failed to clone java repo - exited with code: #{code}"
    end
  end
end
