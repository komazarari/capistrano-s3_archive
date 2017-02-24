# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'capistrano/s3_archive/version'

Gem::Specification.new do |spec|
  spec.name          = "capistrano-s3_archive"
  spec.version       = Capistrano::S3Archive::VERSION
  spec.authors       = ["Takuto Komazaki"]
  spec.email         = ["komazarari@gmail.com"]

  spec.summary       = %q{Capistrano deployment from an archive on Amazon S3.}
  spec.description   = %q{Capistrano deployment from an archive on Amazon S3.}
  spec.homepage      = "https://github.com/komazarari/capistrano-s3_archive"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.required_ruby_version = '>= 2.0.0'
  spec.add_dependency 'capistrano', '~> 3.6.0'
  spec.add_dependency 'aws-sdk-core', '~> 2.0'

  spec.add_development_dependency "bundler", "~> 1.9"
  spec.add_development_dependency "rake", "~> 10.0"
end
