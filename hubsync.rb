#!/usr/bin/env ruby
#
# Syncs all repositories of a user/organization on github.com to a user/organization of a GitHub Enterprise instance.
#
# Usage:
# ./hubsync.rb <github.com organization>        \
#              <github.com access-token>        \
#              <github enterprise url>          \
#              <github enterprise organization> \
#              <github enterprise token>        \
#              <repository-cache-path>
#

require 'rubygems'
require 'bundler/setup'
require 'octokit'
require 'git'
require 'fileutils'
require 'timeout'


module Git

    class Lib
        def clone(repository, name, opts = {})
            @path = opts[:path] || '.'
            clone_dir = opts[:path] ? File.join(@path, name) : name

            arr_opts = []
            arr_opts << "--bare" if opts[:bare]
            arr_opts << "--mirror" if opts[:mirror]
            arr_opts << "--recursive" if opts[:recursive]
            arr_opts << "-o" << opts[:remote] if opts[:remote]
            arr_opts << "--depth" << opts[:depth].to_i if opts[:depth] && opts[:depth].to_i > 0
            arr_opts << "--config" << opts[:config] if opts[:config]

            arr_opts << '--'
            arr_opts << repository
            arr_opts << clone_dir

            command('clone', arr_opts)

            opts[:bare] or opts[:mirror] ? {:repository => clone_dir} : {:working_directory => clone_dir}
        end

        def push(remote, branch = 'master', opts = {})
            # Small hack to keep backwards compatibility with the 'push(remote, branch, tags)' method signature.
            opts = {:tags => opts} if [true, false].include?(opts)

            arr_opts = []
            arr_opts << '--mirror'  if opts[:mirror]
            arr_opts << '--force'  if opts[:force] || opts[:f]
            arr_opts << remote

            if opts[:mirror]
                command('push', arr_opts)
            else
                command('push', arr_opts + [branch])
                command('push', ['--tags'] + arr_opts) if opts[:tags]
            end
        end

        def remote_set_url(name, url, opts = {})
            arr_opts = ['set-url']
            arr_opts << '--push' if opts[:push]
            arr_opts << '--'
            arr_opts << name
            arr_opts << url

            command('remote', arr_opts)
        end
    end


    class Base
        def remote_set_url(name, url, opts = {})
            url = url.repo.path if url.is_a?(Git::Base)
            self.lib.remote_set_url(name, url, opts)
            Git::Remote.new(self, name)
        end
     end
end


def init_github_clients(dotcom_token, enterprise_token, enterprise_url)
    clients = {}
    clients[:githubcom] = Octokit::Client.new(:access_token => dotcom_token, :auto_paginate => true)

    Octokit.configure do |c|
      c.api_endpoint = "#{enterprise_url}/api/v3"
      c.web_endpoint = "#{enterprise_url}"
    end

    clients[:enterprise] = Octokit::Client.new(:access_token => enterprise_token, :auto_paginate => true)
    return clients
end


def create_internal_repository(repo_dotcom, github, organization)
    puts "Repository `#{repo_dotcom.name}` not found on internal Github. Creating repository..."
    return github.create_repository(
        repo_dotcom.name,
        :organization => organization,
        :description => "This repository is automatically synced. Please push changes to #{repo_dotcom.clone_url}",
        :homepage => 'https://larsxschneider.github.io/2014/08/04/hubsync/',
        :has_issues => false,
        :has_wiki => false,
        :has_downloads => false,
        :default_branch => repo_dotcom.default_branch
    )
end


def init_enterprise_repository(repo_dotcom, github, organization)
    repo_int_url = "#{organization}/#{repo_dotcom.name}"
    if github.repository? repo_int_url
        return github.repository(repo_int_url)
    else
        return create_internal_repository(repo_dotcom, github, organization)
    end
end


def init_local_repository(cache_path, repo_dotcom, repo_enterprise)
    FileUtils::mkdir_p cache_path
    repo_local_dir = "#{cache_path}/#{repo_enterprise.name}"

    if File.directory? repo_local_dir
        repo_local = Git.bare(repo_local_dir)
    else
        puts "Cloning `#{repo_dotcom.name}`..."

        repo_local = Git.clone(
            repo_dotcom.clone_url,
            repo_dotcom.name,
            :path => cache_path,
            :mirror => true
        )
        repo_local.remote_set_url('origin', repo_enterprise.clone_url, :push => true)
    end
    return repo_local
end


# GitHub automatically creates special read only refs. They need to be removed to perform a successful push.
# c.f. https://github.com/rtyley/bfg-repo-cleaner/issues/36
def remove_github_readonly_refs(repo_local)
    file_lines = ''

    FileUtils.rm_rf(File.join(repo_local.repo.path, 'refs', 'pull'))

    IO.readlines(File.join(repo_local.repo.path, 'packed-refs')).map do |line|
        file_lines += line unless !(line =~ /^[0-9a-fA-F]{40} refs\/pull\/[0-9]+\/(head|pull|merge)/).nil?
    end

    File.open(File.join(repo_local.repo.path, 'packed-refs'), 'w') do |file|
        file.puts file_lines
    end
end


def sync(clients, dotcom_organization, enterprise_organization, cache_path)
    clients[:githubcom].repositories(dotcom_organization).each do |repo_dotcom|
        begin
            # The sync of each repository must not take longer than 15 min
            Timeout.timeout(60*15) do
                repo_enterprise = init_enterprise_repository(repo_dotcom, clients[:enterprise], enterprise_organization)

                puts "Syncing #{repo_dotcom.name}..."
                puts "    Source: #{repo_dotcom.clone_url}"
                puts "    Target: #{repo_enterprise.clone_url}"
                puts

                repo_enterprise.clone_url = repo_enterprise.clone_url.sub(
                    'https://',
                    "https://#{clients[:enterprise].access_token}:x-oauth-basic@"
                )
                repo_local = init_local_repository(cache_path, repo_dotcom, repo_enterprise)

                repo_local.remote('origin').fetch
                remove_github_readonly_refs(repo_local)
                repo_local.push('origin', repo_dotcom.default_branch, :force => true, :mirror => true)
            end
        rescue StandardError => e
            puts "Syncing #{repo_dotcom.name} FAILED!"
            puts e.message
            puts e.backtrace.inspect
        end
    end
end


if $0 == __FILE__
    dotcom_organization = ARGV[0]
    dotcom_token = ARGV[1]
    enterprise_url = ARGV[2]
    enterprise_organization = ARGV[3]
    enterprise_token = ARGV[4]
    cache_path = ARGV[5]

    clients = init_github_clients(dotcom_token, enterprise_token, enterprise_url)
    while true do
        sleep(1)
        begin
            sync(clients, dotcom_organization, enterprise_organization, cache_path)
        rescue SystemExit, Interrupt
            raise
        rescue Exception => e
            puts "Syncing FAILED!"
            puts e.message
            puts e.backtrace.inspect
        end
    end
end
