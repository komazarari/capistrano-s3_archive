# Capistrano::S3Archive

Capistrano::S3Archive is an extention of [Capistrano](http://www.capistranorb.com/) which enables to `set :scm, :s3_archive`.

This behaves like the [capistrano-rsync](https://github.com/moll/capistrano-rsync) except downloading sources from S3 instead of GIT by default.


## Installation

Add this line to your application's Gemfile:

```ruby
gem 'capistrano-s3_archive'
```

And then execute:

    $ bundle

<!-- Or install it yourself as: -->

<!--     $ gem install capistrano-s3_archive -->

## Usage

`set :scm, :s3_archive` in your config file.

Set a S3 path containing source archives to `repo_url`. For example, if you has following tree,

    s3://yourbucket/somedirectory/
                      |- 201506011200.zip
                      |- 201506011500.zip
                      ...
                      |- 201506020100.zip
                      `- 201506030100.zip

then `set :repo_url, 's3://yourbucket/somedirectory'`.

Set parameters to access Amazon S3:

```ruby
set :s3_client_options, { region: 'ap-northeast-1', credentials: somecredentials }
```

And set regular capistrano options. To deploy staging:
```
$ bundle exec cap staging deploy
```

Or to skip download & extruct archive and deploy local files:
```
$ bundle exec cap staging deploy_only
```


### Configuration
Set parameters with `set :key, value`.

#### Rsync Strategy (default)

Key           | Default | Description
--------------|---------|------------
branch        | `latest` | The S3 Object basename to download. Support `:latest` or such as `'201506011500.zip'`.
version_id    | nil      | Version ID of version-controlled S3 object. It should use with `:branch`. e.g. `set :branch, 'myapp.zip'; set :version_id, 'qawsedrftgyhujikolq'`
sort_proc     | `->(a,b) { b.key <=> a.key }` | Sort algorithm used to detect `:latest` object basename. It should be proc object for `a,b` as `Aws::S3::Object` comparing.
rsync_options | `['-az']` | Options used to rsync.
local_cache   | `tmp/deploy` | Path where to extruct your archive on local for staging and rsyncing. Can be both relative or absolute.
rsync_cache   | `shared/deploy` | Path where to cache your repository on the server to avoid rsyncing from scratch each time. Can be both relative or absolute.<br> Set to `nil` if you want to disable the cache.
s3_archive    | `tmp/archives` | Path where to download source archives. Can be both relative or absolute.


##### Experimental configration
Key           | Default | Description
--------------|---------|------------
hardlink      | nil     | Enable `--link-dest` option when remote rsyncing. It could speed deployment up in the case rsync_cache enabled.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release` to create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

1. Fork it ( https://github.com/[my-github-username]/capistrano-s3_archive/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
