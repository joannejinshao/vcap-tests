require 'rubygems'
require 'rcov'
require 'builder'
require 'zlib'

module Rcov
  class CloverXmlFormatter < BaseFormatter
    def execute
      builder = Builder::XmlMarkup.new(:indent => 2)
      xml = builder.coverage(:generated => Time.now.to_i) do |coverage|
        coverage.project(:timestamp => Time.now.to_i) do |project|
          project_total = 0
          project_covered = 0

          each_file_pair_sorted do |fname, finfo|
            project.file(:name => fname) do |file|
              total = 0
              covered = 0
              finfo.num_lines.times do |i|
                unless finfo.coverage[i] == :inferred
                  total += 1
                  covered += 1 if finfo.coverage[i] == true
                  file.line(:num => i.next, :type => "stmt", :count => finfo.counts[i])
                end
              end

              project_total += total
              project_covered += covered

              file.metrics(:loc => finfo.num_code_lines, :classes => 0, :methods => 0, :coveredmethods => 0, :conditionals => 0, :coveredconditionals => 0,
                           :elements => total, :coveredelements => covered, :statements => total, :coveredstatements => covered)
            end
          end
          project.metrics(:files => @files.size, :loc => num_code_lines, :classes => 0, :methods => 0, :coveredmethods => 0,
                          :elements => project_total, :coveredelements => project_covered, :statements => project_total, :coveredstatements => project_covered)
        end
      end
      puts xml
    end
  end
end

analyzer = Zlib::GzipReader.open(ARGV[0]) do |gz|
  Marshal.load(gz)
end

ignore_regexps = Rcov::BaseFormatter::DEFAULT_OPTS[:ignore]
ignore_regexps += ARGV[1].split(/,/).map{|x| Regexp.new x}
analyzer[:coverage].dump_coverage_info([Rcov::CloverXmlFormatter.new(:ignore => ignore_regexps)])
