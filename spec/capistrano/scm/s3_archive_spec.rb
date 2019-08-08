require "spec_helper"
require "capistrano/scm/s3_archive"

module Capistrano
  describe SCM::S3Archive do
    subject { Capistrano::SCM::S3Archive.new }
    let(:env) { Capistrano::Configuration.env }
    let(:backend) { stub }
    before { SSHKit::Backend.stubs(:current).returns(backend) }
    let(:s3_client) { stub }
    before { Aws::S3::Client.stubs(:new).returns(s3_client) }
    before do
      subject.set_defaults
      env.set(:deploy_to, 'app_deploy_path')
    end

    describe "#local_check" do
      it "should check accessibility by calling listObject API" do
        s3_client.expects(:list_objects)
        subject.local_check
      end
    end
    describe "#remote_check" do
      it "should check accessibility by using awscli 's3 ls'" do
        backend.expects(:execute).with(:aws, 's3', 'ls', any_parameters)
        subject.remote_check
      end
    end
    describe "#strategy"
    describe "#current_version"
    describe "#download_to_local_cache"
    describe "#cleanup_local_cache"
    describe "#transfer_sources"

    describe "#download_to_shared_path" do
      it "should exec 'aws s3 cp'" do
        s3path = 's3://my-test-bucket/prefix/key/'
        remote_path = 'path/to/archives'
        env.set(:repo_url, s3path)
        env.set(:s3_archive_remote_cache_dir, remote_path)
        backend.expects(:execute).with(:aws, 's3', 'cp',
                                       regexp_matches(%r{#{s3path}/}),
                                       regexp_matches(%r{#{remote_path}/}))
        subject.download_to_shared_path
      end
    end
    describe "#cleanup_shared_path" do
      it "should count downloaded archives to remove olders" do
        remote_path = 'path/to/archives'
        env.set(:s3_archive_remote_cache_dir, remote_path)
        backend.expects(:execute).with(:ls, regexp_matches(/[tr]+/), regexp_matches(remote_path))
      end

      it "should delete old archives except newer 'keep_releases'"
    end

    describe "#archive_object_key" do
      it "should return the object key" do
        before do
          s3_client.stubs(:list_objects).returns({  })
        end

        env.set(:repo_url, 's3://my-test-bucket/prefix/key')

        expect(subject.archive_object_key).to eq ''
      end
    end
  end
end
