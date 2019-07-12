$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "..", "lib"))
$LOAD_PATH.unshift(File.dirname(__FILE__))
require "capistrano/all"
require "rspec"
require 'capistrano/s3_archive'

require 'pry'

# Use mocha style following capistrano/capistrano
RSpec.configure do |config|
  config.raise_errors_for_deprecations!
  config.mock_framework = :mocha
  config.order = "random"

  config.around(:example, capture_io: true) do |example|
    begin
      Rake.application.options.trace_output = StringIO.new
      $stdout = StringIO.new
      $stderr = StringIO.new
      example.run
    ensure
      Rake.application.options.trace_output = STDERR
      $stdout = STDOUT
      $stderr = STDERR
    end
  end
end
