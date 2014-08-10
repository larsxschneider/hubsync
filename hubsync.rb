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
        repo_local = Git.open(repo_local_dir)
    else
        puts "Cloning `#{repo_dotcom.name}`..."

        repo_local = Git.clone(
            repo_enterprise.clone_url,
            repo_enterprise.name,
            :path => cache_path,
            :remote => 'enterprise'
        )
        repo_local.add_remote('github.com', repo_dotcom.clone_url)
    end
    return repo_local
end


def sync(clients, dotcom_organization, enterprise_organization, cache_path)
    clients[:githubcom].repositories(dotcom_organization).each do |repo_dotcom|
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

        repo_local.remote('github.com').fetch
        repo_local.checkout("#{repo_dotcom.default_branch}", :force => true)
        repo_local.reset_hard("github.com/#{repo_dotcom.default_branch}")
        repo_local.push('enterprise', repo_dotcom.default_branch, :force => true)
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
    sync(clients, dotcom_organization, enterprise_organization, cache_path) while true
end
