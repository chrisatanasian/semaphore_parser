require 'open-uri'
require 'nokogiri'
require_relative 'semaphore_scraper'

class SemaphoreParser
  def initialize(auth_token, project_name, branch_name, build_number, folder_name)
    scraper = SemaphoreScraper.new(auth_token)

    puts "Downloading build information..."

    hash_id   ||= hash_id(scraper.projects_hash, project_name)
    branch_id ||= branch_id(scraper.branches_hash(hash_id), branch_name)
    @build_stats = scraper.build_stats(hash_id, branch_id, build_number)
    @build_log   = scraper.build_log(hash_id, branch_id, build_number)

    @totals = { tests: 0, assertions: 0, failures: 0, errors: 0, skips: 0 }

    build = "build_#{build_number}"
    @stats_filename           = "#{folder_name}#{build}_stats.txt"
    @combined_output_filename = "#{folder_name}#{build}_thread_output_combined.txt"
    @common_lines_filename    = "#{folder_name}#{build}_thread_output_common_lines.txt"
    @test_numbers_filename    = "#{folder_name}#{build}_thread_output_test_numbers.txt"
  end

  def parse
    @combined_output = File.open("#{@combined_output_filename}", "w+")
    @stats           = File.open("#{@stats_filename}", "w+")

    puts "Compiling all output to: #{@combined_output_filename}..."
    generate_combined_output_and_stats
    @combined_output.close
    @stats.close

    puts "Outputting the common lines in the compiled output to: #{@common_lines_filename}..."
    generate_common_output_lines

    puts "Outputting the test numbers for errors and failures: #{@test_numbers_filename}..."
    generate_test_numbers

    puts "Outputted all statistics to #{@stats_filename}"
  end

  private

  def hash_id(projects_hash, project_name)
    projects_hash.detect { |project_hash| project_hash["name"] == project_name }["hash_id"]
  end

  def branch_id(branches_hash, branch_name)
    branches_hash.detect { |branch_hash| branch_hash["name"] == branch_name }["id"]
  end

  def generate_combined_output_and_stats
    @stats.write(build_information)

    thread_outputs = sorted_threads.map do |thread|
      command       = thread["commands"].last
      thread_number = command["name"].scan(/\d/).join("")
      thread_output = command["output"]

      download_node = Nokogiri::HTML(thread_output).css(".text-info").css("a").first
      download_link = download_node.attributes["href"].value if download_node.respond_to?(:attributes)

      if download_link
        thread_output = File.read(open(download_link))
      end

      write_thread_totals_to_stats(thread_number, thread_output)

      ["THREAD #{thread_number}:\n", thread_output]
    end.flatten.compact

    @combined_output.write(thread_outputs.join("\n"))

    write_combined_totals_to_stats
  end

  def sorted_threads
    @build_log["threads"].sort_by { |thread| thread["commands"].last["name"].scan(/\d/).join("").to_i }
  end

  def thread_stats_regex_runs
    /\d+ runs, \d+ assertions, \d+ failures, \d+ errors, \d+ skips/
  end

  def thread_stats_regex_tests
    /\d+ tests, \d+ assertions, \d+ failures, \d+ errors, \d+ skips/
  end

  def thread_stats_regex_omissions
    /\d+ tests, \d+ assertions, \d+ failures, \d+ errors, \d+ pendings, \d+ omissions, \d+ notifications/
  end

  def build_information
    ["build #{@build_stats["number"]} for #{@build_stats["project_name"]}",
     "branch: #{@build_stats["branch_name"]}",
     "commit: #{@build_stats["commits"].first["url"]}\n\n"].join("\n")
  end

  def add_to_totals(stats_line)
    line_totals = stats_line.scan(/\d+/)
    @totals.each_with_index { |(key, _), i| @totals[key] += line_totals[i].to_i }
  end

  def write_thread_totals_to_stats(thread_number, thread_output)
    stats_line_array = thread_output.scan(thread_stats_regex_tests)
    stats_line_array = thread_output.scan(thread_stats_regex_runs) if stats_line_array.empty?
    stats_line_array = thread_output.scan(thread_stats_regex_omissions) if stats_line_array.empty?

    if stats_line_array.any?
      @stats.print("#{thread_number}: ")
      @stats.write(stats_line_array.join("\n   ") + "\n")
      stats_line_array.map { |thread_output_line| add_to_totals(thread_output_line) }
    end
  end

  def write_combined_totals_to_stats
    @stats.write("\n")
    @totals.each { |key, value| @stats.write("#{value} #{key}\n") }
    @stats.write("\nfailures + errors + skips: #{@totals[:failures] + @totals[:errors] + @totals[:skips]}")
  end

  def generate_common_output_lines
    common_lines_command = "cat #{@combined_output_filename} | grep -v \"^\s*$\" | sort | uniq -c | sort -nr > #{@common_lines_filename}"
    system(common_lines_command)
  end

  def generate_test_numbers
    common_lines_command = "grep -oG '.*Test#' #{@combined_output_filename} | uniq -c | sort -n > #{@test_numbers_filename}"
    system(common_lines_command)
  end
end

if __FILE__ == $0
  semaphore_parser = SemaphoreParser.new(ARGV[0], ARGV[1], ARGV[2], ARGV[3], ARGV[4] || "")
  semaphore_parser.parse
end
