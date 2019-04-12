require 'spec_helper'
require "capistrano/s3_archive/version"

module Capistrano
  describe S3Archive do
    it 'has a version number' do
      expect(Capistrano::S3Archive::VERSION).not_to be nil
    end
  end
end
