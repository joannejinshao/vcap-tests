module RakeDefs
  module_function
  def set_root(subdir = nil)
    path = root = File.expand_path('../../..', __FILE__)
    path = File.join(path, subdir) if subdir
    unless Dir.pwd == path
      Dir.chdir(path)
    end
    path
  end
end

# Tasks to help tracking of 3rd party libraries / gems usage in AppCloud core
namespace "oss" do

  components = ["dea", "health_manager", "router", "cloud_controller", "dashboard"]
  IGNORE_GEM_LIST = ["vcap_common"]
  OSS_SPECS_DIR = "lib/oss"

  task :update_gem_list, [:component] do |t, args|
    if args.component.nil?
      puts "Component input not provided"
    elsif components.include?(args.component)
      save_gem_list(args.component)
    else
      puts "No matching component for '#{args.component}' - skipping update"
    end
  end

  desc "Update saved gem list for each component as well as an aggregate list"
  task :update_gem_lists do
    gem_list = {}
    components.each do |component|
      Rake::Task['oss:update_gem_list'].reenable
      Rake::Task['oss:update_gem_list'].invoke(component)
      merge_gem_lists(component, gem_list, generate_gem_list(component))
    end
    RakeDefs.set_root "tests"
    Dir.chdir(OSS_SPECS_DIR)
    File.open("appcloud.ossdeps", "w") {|f| YAML.dump(gem_list, f)}
  end

  task :compare_gem_list, [:component] do |t, args|
    if args.component.nil?
      puts "Component input not provided"
    elsif components.include?(args.component)
      compare_lists(args.component)
    else
      puts "No matching component for '#{args.component}' - skipping update"
    end
  end

  desc "Detect changes in gem usage - if there is a change, the task will fail at the first such change with a report of the updates"
  task :detect_gem_changes do
    components.each do |component|
      Rake::Task['oss:compare_gem_list'].reenable
      Rake::Task['oss:compare_gem_list'].invoke(component)
    end
  end

  def generate_gem_list component
    gems = {}
    RakeDefs.set_root
    Dir.chdir(component)
    # components may share Gemfiles with other components,
    # e.g. HealthManager and CloudController
    return gems unless File.exists?('Gemfile.lock')
    File.open("Gemfile.lock") do |f|
      lock = Bundler::LockfileParser.new(f.read)
      lock.specs.map {|s| gems.store(s.name, s.version.version) unless IGNORE_GEM_LIST.include?(s.name) }
    end
    Dir.chdir("..")
    gems
  end

  def save_gem_list component
    gems = generate_gem_list(component)
    RakeDefs.set_root "tests"
    Dir.chdir(OSS_SPECS_DIR)
    File.open("#{component}.ossdeps", "w") {|f| YAML.dump(gems, f)}
  end

  def get_saved_gem_list component
    RakeDefs.set_root "tests"
    Dir.chdir(OSS_SPECS_DIR)
    saved_gems = YAML.load_file("#{component}.ossdeps")
    saved_gems
  end

  def compare_lists component
    current_gems = generate_gem_list(component)
    saved_gems = get_saved_gem_list(component)
    if (current_gems == saved_gems)
      puts "No change in gem dependencies for '#{component}'"
    else
      generate_comparison_report(component, current_gems, saved_gems)
    end
  end

  def generate_comparison_report(component, current_gems, saved_gems)
    report = { :added => [], :deleted => [], :changes => [] }
    current_gems.keys.each do |key|
      saved_value = saved_gems.delete(key)
      current_value = current_gems[key]
      if saved_value.nil?
        pair = "#{key}: #{current_value}"
        report[:added] << pair
      else
        if saved_value != current_value
          report[:changes] << Change.new(key, current_value, saved_value)
        end
      end
    end
    unless saved_gems.empty?
      saved_gems.each_pair do |key, value|
        pair = "#{key}: #{value}"
        report[:deleted] << pair
      end
    end
    message = "\nGem dependencies have changed - comparison report follows:"
    message << "\n--- Begin ---"
    message << "\n\tComponent: '#{component}'"
    unless report[:added].empty?
      message << "\n\tAdded gems: " << report[:added].join(", ")
    end
    unless report[:deleted].empty?
      message << "\n\tDeleted gems: " << report[:deleted].join(", ")
    end
    unless report[:changes].empty?
      message << "\n\tChanged gems: " << report[:changes].join(", ")
    end
    message << "\n---- End ----"
    message << "\n\nPlease file a Pivotal chore to update our OSS legal notices "
    message << "with the contents of the report above. Thereafter, proceed by: "
    message << "1. running the 'rake oss:update_gem_lists' in the 'tests' dir "
    message << "2. checking in the resulting updates to the tests/lib/oss directory\n"
    raise message
  end

  def merge_gem_lists(component, hash1, hash2=nil)
    unless hash2.nil? || hash2.empty?
      hash2.keys.each do |key|
        unless hash1.has_key?(key)
          hash1[key] = []
          hash1[key].push(hash2[key])
        else
          val1 = hash1[key][0]
          val2 = hash2[key]
          hash1[key].push(hash2[key])
          hash1[key].sort!.uniq!
          unless val2 == val1
            puts "*** Warning *** Version '#{val2}' of gem '#{key}' being used in '#{component}' differs from version '#{val1}' being used in other components. Please resolve this by using the same version of the gem in all components"
          end
        end
      end
    end
    hash1
  end

  class Change
    attr_reader :name, :from, :to

    def initialize(name, from, to)
      @name = name
      @from = from
      @to = to
    end

    def to_s
      "#{@name}: #{@from} -> #{@to}"
    end
  end
end
