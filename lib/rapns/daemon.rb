require 'thread'
require 'socket'
require 'pathname'

require 'rapns/daemon/interruptible_sleep'
require 'rapns/daemon/configuration'
require 'rapns/daemon/delivery_error'
require 'rapns/daemon/disconnection_error'
require 'rapns/daemon/connection'
require 'rapns/daemon/database_reconnectable'
require 'rapns/daemon/delivery_queue'
require 'rapns/daemon/delivery_handler'
require 'rapns/daemon/delivery_handler_pool'
require 'rapns/daemon/feedback_receiver_pool'
require 'rapns/daemon/feedback_receiver'
require 'rapns/daemon/feeder'
require 'rapns/daemon/logger'

module Rapns
  module Daemon
    extend DatabaseReconnectable

    class << self
      attr_accessor :logger, :queues, :handler_pool, :receiver_pool, :configuration
    end

    def self.start(environment, foreground)
      setup_signal_hooks

      self.configuration = Configuration.load(environment, File.join(Rails.root, 'config', 'rapns', 'rapns.yml'))
      self.logger = Logger.new(:foreground => foreground, :airbrake_notify => configuration.airbrake_notify)

      unless foreground
        daemonize
        reconnect_database
      end

      write_pid_file

      self.handler_pool = DeliveryHandlerPool.new
      self.receiver_pool = FeedbackReceiverPool.new
      self.queues = {}

      ensure_upgraded

      apps = Rapns::App.where(:environment => environment)
      if apps.empty?
        puts "!!!!!!!!!!"
        puts "You must create an app for environment '#{environment}'."
        puts "See https://github.com/ileitch/rapns for instructions."
        exit 1
      end
      apps.each { |app| start_app(app) }
      Feeder.start(configuration.push.poll)
    end

    protected

    def self.start_app(app)
      queue = queues[app.key] ||= DeliveryQueue.new

      app.connections.times do |i|
        host = configuration.push.host
        port = configuration.push.port
        handler = DeliveryHandler.new(queue, "#{app.key}:#{i}", host, port, app.certificate, app.password)
        handler_pool << handler
      end

      feedback = configuration.feedback
      receiver = FeedbackReceiver.new(app.key, feedback.host, feedback.port, feedback.poll, app.certificate, app.password)
      receiver_pool << receiver
    end

    def self.ensure_upgraded
      Rapns::App.count
    rescue ActiveRecord::StatementInvalid
      puts "!!!!!!!!!!"
      puts "As of version v2.0.0 apps are configured in the database instead of rapns.yml."
      puts "Please run 'rails g rapns' to generate the new migrations and create your apps with Rapns::App."
      puts "See https://github.com/ileitch/rapns for further instructions."
      exit 1
    end

    def self.setup_signal_hooks
      @shutting_down = false

      ['SIGINT', 'SIGTERM'].each do |signal|
        Signal.trap(signal) { handle_shutdown_signal }
      end
    end

    def self.handle_shutdown_signal
      exit 1 if @shutting_down
      @shutting_down = true
      shutdown
    end

    def self.shutdown
      puts "\nShutting down..."
      Rapns::Daemon::Feeder.stop
      Rapns::Daemon.handler_pool.drain if Rapns::Daemon.handler_pool
      Rapns::Daemon.receiver_pool.drain if Rapns::Daemon.receiver_pool
      delete_pid_file
    end

    def self.daemonize
      exit if pid = fork
      Process.setsid
      exit if pid = fork

      Dir.chdir '/'
      File.umask 0000

      STDIN.reopen '/dev/null'
      STDOUT.reopen '/dev/null', 'a'
      STDERR.reopen STDOUT
    end

    def self.write_pid_file
      if !configuration.pid_file.blank?
        begin
          File.open(configuration.pid_file, 'w') { |f| f.puts Process.pid }
        rescue SystemCallError => e
          logger.error("Failed to write PID to '#{configuration.pid_file}': #{e.inspect}")
        end
      end
    end

    def self.delete_pid_file
      pid_file = configuration.pid_file
      File.delete(pid_file) if !pid_file.blank? && File.exists?(pid_file)
    end
  end
end