# Shared properties and paths for the CI system.
module BuildConfig
  module_function
  def controller_host
    if ENV.key?('VCAP_BVT_TARGET')
      "api.#{ENV['VCAP_BVT_TARGET']}"
    else
      "api.vcap.me"
    end
  end

  # TODO - Make these shared values configurable. ci.yml in profile directory?
  # We don't want to have to process yaml files in a specific order,
  # but the service gateway config files expect to list this hostname.
  def nats_uri
    'nats://localhost:4299/'
  end
  def nats_pid
    File.join(working_dir, 'run', 'nats-server.pid')
  end
  def controller_port
    8079
  end
  def router_port
    2222
  end
  def dea_filer_port
    12350
  end
  # How long should we wait for the cloud to start?
  def startup_timeout
    90
  end

  def platform_cache_dir
    File.join(ENV['HOME'], '.vcap_gems')
  end

  def bundle_path
    File.join(ENV['HOME'], 'ci-bundler-dir', RUBY_VERSION)
  end

  def bundle_cmd(to_wrap)
    env = "unset BUNDLE_GEMFILE;export BUNDLE_PATH=#{bundle_path};"
    "#{env}#{to_wrap}"
  end

  def artifacts_dir
    File.join(CoreComponents.root, 'tests', 'ci-artifacts-dir')
  end

  def working_dir
    File.join(CoreComponents.root, 'tests', 'ci-working-dir')
  end

  def test_result_dir
    File.join(artifacts_dir, 'test-results')
  end

  def log_dir
    File.join(artifacts_dir, 'logs')
  end

  def config_dir
    File.join(working_dir, 'config')
  end

  def manifest_dir
    File.join(working_dir, 'manifests')
  end

  def profile_base_dir
    File.join(CoreComponents.root, 'tests', 'profiles')
  end

  def startup_script
    File.join(working_dir, 'startup')
  end

  def service_startup_script
    File.join(working_dir, 'service_startup')
  end

  def java_temp_dir
    File.join(working_dir, 'tmp')
  end

  def java_client_dir
    File.join(java_temp_dir, 'java', 'AppCloudClient')
  end

  # The tests/profiles directory supports subdirs.
  # The default is 'acdev'; set the VCAP_CI_PROFILE variable to pick another.
  def generate(profile)
    dir = File.join(profile_base_dir, profile)
    unless File.directory?(dir)
      fail "Unknown CI profile: #{profile.inspect}"
    end
    template = BuildTemplate.new(dir)
    template.generate
  end

  def fetch_option(component_path, option_name)
    path = File.join(config_dir, "#{component_path}.yml")
    data = YAML.load_file(path)
    data[option_name.to_s]
  end
end


