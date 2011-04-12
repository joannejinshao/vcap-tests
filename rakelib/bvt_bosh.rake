require 'yaml'
require 'fileutils'
require 'tempfile'

# Keep our state in a seperate class so that we don't pollute the
# global environment
class BoshBvtEnv
  # FIXME: move tese to a config file and move to a dedicated dev
  # env.  Dev5 is peb's.
  BOSH_TARGET     = "http://172.31.113.145:25555"
  BOSH_MANIFEST   = "dev5.yml"
  BOSH_USER       = "admin"
  BOSH_PASSWORD   = "admin"

  # The following are all relative to the test dir root.
  # FIXME: move these to config files too and figure out where
  # they should be on the bamboo system.  Bamboo will have
  # already checked out core,
  CORE_DIR        = "../../core"
  RELEASE_DIR     = "../../release"
  DEPLOYMENTS_DIR = "../../deployments"

  attr_reader :root_dir, :release_dir, :config_dir, :director_url,
              :manifest_src, :manifest_file, :core_dir, :release_cfg,
              :bosh_user, :bosh_password, :results_dir

  def initialize
    @root_dir        = File.expand_path("..", File.dirname(__FILE__))
    @config_dir      = File.expand_path("config", @root_dir)
    @release_dir     = File.expand_path(RELEASE_DIR, @root_dir)
    @manifest_src    = File.expand_path("#{DEPLOYMENTS_DIR}/#{BOSH_MANIFEST}", @root_dir)
    @manifest_file   = Tempfile.new('manifest')
    @director_url    = BOSH_TARGET
    @bosh_user       = BOSH_USER
    @bosh_password   = BOSH_PASSWORD
    @core_dir        = File.expand_path(CORE_DIR, @root_dir)
    @results_dir     = File.expand_path("ci-artifacts-dir", @root_dir)
  end
end

namespace :ci_bosh do
  bosh_env = BoshBvtEnv.new

  desc "Set BOSH target"
  task :target do
    url = bosh_env.director_url
    puts "Setting BOSH target to #{url}"
    rslt = `bosh target #{url}`
    if not /Target set to '.* \(#{url}\)'/.match(rslt)
      fail "Cloud not set bosh target. Result: #{rslt}"
    end
  end

  desc "Login to BOSH"
  task :login => [:target] do
    puts "Logging into BOSH as '#{bosh_env.bosh_user}'"
    rslt = `bosh login #{bosh_env.bosh_user} #{bosh_env.bosh_password}`
    if not /Logged in as '#{bosh_env.bosh_user}'/.match(rslt)
      fail "Could not login to bosh. Result: #{rslt}"
    end
  end

  desc "Set BOSH deployment"
  task :deployment do
    man = bosh_env.manifest_file.path
    puts "Setting BOSH deployment"
    rslt = `bosh deployment #{man}`
    if not /Deployment set to .*/.match(rslt)
      fail "Could not set bosh deployment. Result: #{rslt}"
    end
  end

  desc "Checkout release"
  task :checkout_release do
    puts "Checking out release"
    Dir.chdir(bosh_env.release_dir) do
      system "git pull"
    end
  end

  desc "Update core"
  task :update_core do
    puts "Updating core"
    Dir.chdir(bosh_env.release_dir) do
      # TODO: add ability to do selectively do official submodule
      # update or release right from HEAD of real core
      FileUtils::rm_rf("src/core")
      FileUtils::ln_s(bosh_env.core_dir, "src/core")
    end
  end

  desc "Clean releases"
  task "clean_releases" do
    puts "Cleaning local versions of old releases"
    Dir.chdir(bosh_env.release_dir) do
      FileUtils.rm Dir.glob('dev_releases/*.tgz')
    end
  end

  desc "Create release"
  task :create_release => [:checkout_release, :clean_releases, :update_core] do
    puts "Creating release"
    Dir.chdir(bosh_env.release_dir) do
      initial_cfg = YAML.load_file("config/dev.yml")
      rslt = `bosh create release --force`
      new_cfg = YAML.load_file("config/dev.yml")
      if new_cfg['version'] == initial_cfg['version']
        fail "bosh create release did not generate a new release, still on version #{new_cfg['version']}"
      end
    end
  end

  desc "Upload latest release"
  task :upload_latest_release => [:login] do
    puts "Uploading latest release"
    Dir.chdir(bosh_env.release_dir) do
      cfg = YAML.load_file("config/dev.yml")
      release_tgz = "dev_releases/#{cfg['name']}-#{cfg['version']}.tgz"
      rslt = `bosh upload release #{release_tgz}`
      if not /Task [\d]+: state is 'done'/.match(rslt)
        fail "bosh upload release failed. Result:\n#{rslt}"
      end
    end
  end

  desc "Generate manifest"
  task :generate_manifest do
    puts "Generating manifest"
    cfg = YAML.load_file("#{bosh_env.release_dir}/config/dev.yml")
    manifest = YAML.load_file(bosh_env.manifest_src)
    ['release', 'name'].each { |k| manifest['release'][k] = cfg[k] }
    bosh_env.manifest_file.rewind
    bosh_env.manifest_file << manifest.to_yaml
    bosh_env.manifest_file.flush
  end

  # This is not actually used as it will cause the deployment
  # to be really slow.  But it is here in case we ever want to
  # do it all the time, or maybe if a bvt tests fails we could
  # do a delete and redploy to see if it was due to stale test
  # state or something.
  desc "Delete deployment"
  task :delete_deployment do
    puts "Deleting deployment"
    cfg = YAML.load_file(bosh_env.manifest_src)
    rslt = `bosh delete deployment #{cfg['name']}`
    if not /Task [\d]+: state is 'done'/.match(rslt)
      fail "bosh delete deployment failed. Result:\n#{rslt}"
    end
  end

  desc "Deploy AppCloud via BOSH"
  task :deploy => [:login, :generate_manifest, :deployment] do
    puts "Deploying release via BOSH"
    rslt = `bosh deploy`
    if not /Task [\d]+: state is 'done'/.match(rslt)
      fail "bosh deploy failed. Result:\n#{rslt}"
    end
  end

  desc "Set BVT enviornment"
  task :bvt_env do
    cfg = YAML.load_file(bosh_env.manifest_src)
    ENV['VCAP_BVT_TARGET'] = cfg['properties']['domain']
    ENV.delete('BUNDLE_PATH')  # was causing issues.. TODO: ask AB why he sets this
  end

  desc "Run BVT"
  task :bvt => [:bvt_env] do
    puts "Starting BVT against #{ENV['VCAP_BVT_TARGET']}"
    root = File.join(CoreComponents.root, 'tests')
    cmd = BuildConfig.bundle_cmd("bundle exec cucumber --format junit -o #{bosh_env.results_dir}")
    sh "\tcd #{root}; #{cmd}" do |success, exit_code|
      if success
        puts "BVT completed successfully"
      else
        fail "BVT did not complete successfully - exited with code: #{exit_code.exitstatus}"
      end
    end
  end

  task :java_client_tests => [:bvt_env] do
    puts "Starting Java client driven tests against #{ENV['VCAP_BVT_TARGET']}"
    puts "NOT IMPLEMENTED."

    # TODO: Code below copied from bvt.rake, but the tools directory is
    # not in the repo.  Where does the ci system get it from?
    #
    # NOTE(wlb): Check out the 'clone_repo' task in rakelib/java_client.rake
    #RakeDefs.set_root "tools/sts/AppCloudClient"
    #sh "\tmvn -Dvcap.target.domain=vcap.me -e -ff clean test" do |success, exit_code|
    #  if success
    #    puts "Java client tests completed successfully"
    #  else
    #    fail "Java client tests did not complete successfully - exited with code: #{exit_code.exitstatus}"
    #  end
    #end
  end

  # The dependencies for all actions are on this task rather than
  # putting a dependency of :create_release on :upload_latest,
  # for example, so that the individual tasks can be run in isolation
  # for debugging.
  desc "Deploy environment via BOSH for testing"
  task :create_and_deploy => [:create_release, :upload_latest_release, :deploy] do; end

  task :ci_tests      => [:create_and_deploy, :bvt] do; end
  task :ci_java_tests => [:create_and_deploy, :java_client_tests] do; end
end

