#!/usr/bin/env ruby
# coding: utf-8
require 'rainbow'
require 'peach'
require 'json'
require 'clamp'
require 'net/ssh'
require 'net/scp'

def infohelper(nodes, parseable, grepable)
  if parseable
    puts nodes.to_json
  else
    nodes.each do |node|
      @host = "#{node['role']}:#{node['environment']}:#{node['instance']}"
      unless grepable
        puts @host.color(:green)
      end
      node.keys.each do |key|
        if grepable
          puts "#{@host}|#{key}|#{node[key]}"
        else
          unless key == node.keys.last
            puts "  ┠  #{key.color(:cyan)}: #{node[key]}"
          else
            puts "  ┖  #{key.color(:cyan)}: #{node[key]}\n\n"
          end
        end
      end
    end
  end
end

def sshcmd(node, commands)
  Net::SSH.start(
    node['hostname'],
    'admin',
    :key_data => [$api.ssh(node['role'], node['environment'], node['instance'])['key']],
    :config => false,
    :keys_only => true,
    :paranoid => false
  ) do |ssh|
    stdout_data = ""
    stderr_data = ""
    exit_code = nil
    exit_signal = nil
    commands.each do |command|
      ssh.open_channel do |channel|
        channel.exec(command) do |ch, success|
          unless success
            abort "FAILED: couldn't execute command (ssh.channel.exec)"
          end
          channel.on_data do |ch,data|
            puts "#{node['role'].color(:yellow)}:#{node['environment'].color(:yellow)}:#{node['instance'].color(:yellow)}> #{data}"
          end

          channel.on_extended_data do |ch,type,data|
            puts "#{node['role'].color(:yellow)}:#{node['environment'].color(:yellow)}:#{node['instance'].color(:red)}> #{data}"
          end

          channel.on_request("exit-status") do |ch,data|
            exit_code = data.read_long
            if exit_code != 0
              exit exit_code
            end
          end

          channel.on_request("exit-signal") do |ch, data|
            exit_signal = data.read_string
          end
        end
      end
    end
#    ssh.loop
#    [stdout_data, stderr_data, exit_code, exit_signal]
  end
end

#def sshcmd(node, commands)
#  commands.each do |command|
#    ssh_exec!(node, command)
#  end
#end

module Gaptool
  class InitCommand < Clamp::Command
    option ["-r", "--role"], "ROLE", "Resource name to initilize", :required => true
    option ["-e", "--environment"], "ENVIRONMENT", "Which environment, e.g. production", :required => true
    option ["-z", "--zone"], "ZONE", "AWS availability zone to put node in", :required => true
    option ["-t", "--type"], "TYPE", "Type of instance, e.g. m1.large", :required => true
    option ["-m", "--mirror"], "GIGABYTES", "Gigs for raid mirror, must be set up on each node", :required => false
    def execute
      $api.addnode(zone, type, role, environment, mirror)
    end
  end

  class TerminateCommand < Clamp::Command
    option ["-z", "--zone"], "ZONE", "AWS availability zone to put node in", :required => true
    option ["-i", "--instance"], "INSTANCE", "Instance ID, e.g. i-12345678", :required => true
    def execute
      $api.terminatenode(instance, zone)
    end
  end

  class SshCommand < Clamp::Command
    option ["-r", "--role"], "ROLE", "Role name to ssh to", :required => true
    option ["-e", "--environment"], "ENVIRONMENT", "Which environment, e.g. production", :required => true
    option ["-i", "--instance"], "INSTANCE", "Node instance, leave blank to query avilable nodes", :require => false
    option ["-f", "--first"], :flag, "Just connect to first available instance"
    option ["-t", "--tmux"], :flag, "Open cluster in windows in a tmux session"

    def execute
      if tmux?
        nodes = $api.getenvroles(role, environment)
        system "tmux start-server"
        nodes.each_index do |i|
          @ssh = $api.ssh(role, environment, nodes[i]['instance'])
          if i == 0
            system "tmux new-session -d -s #{role}-#{environment} -n #{nodes[i]['instance']}"
          else
            system "tmux new-window -t #{role}-#{environment}:#{i} -n #{nodes[i]['instance']}"
          end
          File.open("/tmp/gtkey-#{nodes[i]['instance']}", 'w') {|f| f.write(@ssh['key'])}
          File.chmod(0600, "/tmp/gtkey-#{nodes[i]['instance']}")
          system "tmux send-keys -t #{role}-#{environment}:#{i} 'SSH_AUTH_SOCK=\"\" ssh -i /tmp/gtkey-#{nodes[i]['instance']} admin@#{@ssh['hostname']}' C-m"
        end
        system "tmux attach -t #{role}-#{environment}"
      else
        if instance
          @ssh = $api.ssh(role, environment, instance)
        else
          nodes = $api.getenvroles(role, environment)
          if first? || nodes.size == 1
            puts "No instnace specified, but only one instance in cluster or first forced"
            @ssh = $api.ssh(role, environment, nodes.first['instance'])
          else
            puts "No instance specified, querying list."
            nodes.each_index do |i|
              puts "#{i}: #{nodes[i]['instance']}"
            end
            print "Select a node: ".color(:cyan)
            @ssh = $api.ssh(role, environment, nodes[$stdin.gets.chomp.to_i]['instance'])
          end
        end
        File.open('/tmp/gtkey', 'w') {|f| f.write(@ssh['key'])}
        File.chmod(0600, '/tmp/gtkey')
        system "SSH_AUTH_SOCK='' ssh -i /tmp/gtkey admin@#{@ssh['hostname']}"
      end
    end

  end

  class InfoCommand < Clamp::Command
    option ["-r", "--role"], "ROLE", "Role name, e.g. frontend", :required => false
    option ["-e", "--environment"], "ENVIRONMENT", "Which environment, e.g. production", :required => false
    option ["-i", "--instance"], "INSTANCE", "Node instance, leave blank to query avilable nodes", :required => false
    option ["-p", "--parseable"], :flag, "Display in non-pretty parseable JSON"
    option ["-g", "--grepable"], :flag, "Display in non-pretty grep-friendly text"

    def execute
      @nodes = Array.new
      if instance
        @nodes = [$api.getonenode(instance)]
      elsif role && environment
        @nodes = $api.getenvroles(role, environment)
      elsif role && !environment
        @nodes = $api.getrolenodes(role)
      else
        @nodes = $api.getallnodes()
      end
      infohelper(@nodes, parseable?, grepable?)
    end
  end

  class ChefrunCommand < Clamp::Command
    option ["-r", "--role"], "ROLE", "Role name to ssh to", :required => true
    option ["-e", "--environment"], "ENVIRONMENT", "Which environment, e.g. production", :required => true
    option ["-i", "--instance"], "INSTANCE", "Instance ID, e.g. i-12345678", :required => false

    def execute
      if !instance.nil?
        nodes = [$api.getonenode(instance)]
      else
        nodes = $api.getenvroles(role, environment)
      end
      nodes.peach do |node|
        json = {
          'this_server' => "#{role}-#{environment}-#{node['instance']}",
          'role' => role,
          'environment' => environment,
          'app_user' => node['appuser'],
          'run_list' => [ "recipe[main]" ],
          'hostname' => node['hostname'],
          'instance' => node['instance'],
          'zone' => node['zone'],
          'itype' => node['itype'],
          'apps' => eval(node['apps'])
        }.to_json
        commands = [
          "cd ~admin/ops; git pull",
          "echo '#{json}' > ~admin/solo.json",
          "sudo chef-solo -c ~admin/ops/cookbooks/solo.rb -j ~admin/solo.json"
        ]
        sshcmd(node, commands)
      end
    end
  end

  class DeployCommand < Clamp::Command
    option ["-a", "--app"], "APP", "Application to deploy", :required => true
    option ["-m", "--migrate"], :flag, "Toggle running migrations"
    option ["-e", "--environment"], "ENVIRONMENT", "Which environment, e.g. production", :required => true
    option ["-b", "--branch"], "BRANCH", "Git branch to deploy, default is master", :required => false
    option ["-r", "--rollback"], :flag, "Toggle this to rollback last deploy"
    option ["-i", "--instance"], "INSTANCE", "Instance ID, e.g. i-12345678", :required => false

    def execute
      if instance
        nodes = [$api.getonenode(instance)]
      else
        nodes = $api.getappnodes(app, environment)
      end
      nodes.peach do |node|
        json = {
          'this_server' => "#{node['role']}-#{environment}-#{node['instance']}",
          'role' => node['role'],
          'environment' => environment,
          'app_user' => node['appuser'],
          'run_list' => [ "recipe[deploy]" ],
          'hostname' => node['hostname'],
          'instance' => node['instance'],
          'zone' => node['zone'],
          'itype' => node['itype'],
          'apps' => eval(node['apps']),
          'app_name' => app,
          'app' => app,
          'rollback' => rollback?,
          'branch' => branch || 'master',
          'migrate' => migrate?
        }.to_json
        commands = [
          "cd ~admin/ops; git pull",
          "echo '#{json}' > ~admin/solo.json",
          "sudo chef-solo -c ~admin/ops/cookbooks/solo.rb -j ~admin/solo.json"
        ]
        sshcmd(node, commands)
      end
    end
  end

  class RegenCommand < Clamp::Command
    option ["-z", "--zone"], "ZONE", "AWS availability zone to put node in", :required => true
    def execute
      nodes = $api.regenhosts(zone)
    end
  end

  class BalanceCommand < Clamp::Command
    option ["-r", "--role"], "ROLE", "Role name to ssh to", :required => true
    option ["-e", "--environment"], "ENVIRONMENT", "Which environment, e.g. production", :required => true
    def execute
      puts $api.balanceservices(role, environment)
    end
  end

  class AddserviceCommand < Clamp::Command
    option ["-r", "--role"], "ROLE", "Role name to ssh to", :required => true
    option ["-e", "--environment"], "ENVIRONMENT", "Which environment, e.g. production", :required => true
    option ["-n", "--name"], "NAME", "Name of the service, e.g. 'twitter'. MUST MATCH UPSTARTD SERVICE NAME.", :required => true
    option ["-w", "--weight"], "WEIGHT", "Relative service weight, for the balancer to chose run location", :required => true
    option ["-y", "--enabled"], :flag, "Enable this service in balance run"
    option ["-k", "--keys"], "KEYS", "Hash of keys that will be written to YAML /tmp/apikeys-<service name>.yml. This will be eval()'d, write it like a ruby hash.", :required => true
    def execute
      if enabled?
        en = 1
      else
        en = 0
      end
      puts $api.addservice(role, environment, name, eval(keys), weight, en)
    end
  end

  class DelserviceCommand < Clamp::Command
    option ["-r", "--role"], "ROLE", "Role name to ssh to", :required => true
    option ["-e", "--environment"], "ENVIRONMENT", "Which environment, e.g. production", :required => true
    option ["-n", "--name"], "NAME", "Name of the service, e.g. 'twitter'. MUST MATCH UPSTARTD SERVICE NAME.", :required => true
    def execute
      puts $api.deleteservice(role, environment, name)
    end
  end

  class ServicesCommand < Clamp::Command
    def execute
      puts $api.getservices()
    end
  end

  class SvcAPIList < Clamp::Command
    option [ "-s", "--service"], "SERVICE", "Name of the service, omit to show all"
    def execute
      if service.nil?
        keyhash = $api.svcapi_showkeys(:all)
        keyhash.keys.each do |service|
          puts service.color(:green)
          keyhash[service].keys.each do |state|
            puts "  ┖  #{state}".color(:cyan)
            keyhash[service][state].each do |key|
              puts "    - #{key}"
            end
          end
        end
      else
        keyhash = $api.svcapi_showkeys(service)
        puts service.color(:green)
        keyhash.keys.each do |state|
          puts "  ┖  #{state}".color(:cyan)
          keyhash[state].each do |key|
            puts "    - #{key}"
          end
        end
      end
    end
  end

  class SvcAPIDelete < Clamp::Command
    option [ "-s", "--service"], "SERVICE", "Name of the service", :required => true
    option [ "-k", "--key" ], "KEY", "string for storing as a key/deleting", :required => true
    def execute
      if $api.svcapi_deletekey(service, key)
        puts "success"
      end
    end
  end

  class SvcAPIPut < Clamp::Command
    option [ "-s", "--service"], "SERVICE", "Name of the service", :required => true
    option [ "-k", "--key" ], "KEY", "string for storing as a key/deleting", :required => true
    def execute
      puts $api.svcapi_putkey(service, key)
    end
  end

  class SvcAPI < Clamp::Command
    subcommand "list", "List keys for a service or all services", SvcAPIList
    subcommand "delete", "Delete key from a service", SvcAPIDelete
    subcommand "put", "Put a new key for a service", SvcAPIPut
  end

  class MainCommand < Clamp::Command

    subcommand "info", "Displays information about nodes", InfoCommand
    subcommand "init", "Create new application cluster", InitCommand
    subcommand "terminate", "Terminate instance", TerminateCommand
    subcommand "ssh", "ssh to cluster host", SshCommand
    subcommand "chefrun", "chefrun on a resource pool", ChefrunCommand
    subcommand "deploy", "deploy on an application", DeployCommand
    subcommand "regen", "regen metadata from aws", RegenCommand
    subcommand "balance", "balance services across nodes based on weight", BalanceCommand
    subcommand "addservice", "add new service to service framework", AddserviceCommand
    subcommand "delservice", "delete last service", DelserviceCommand
    subcommand "services", "show all services", ServicesCommand
    subcommand "svcapi", "manipulate service API keys/metadata", SvcAPI

  end
end

Gaptool::MainCommand.run
