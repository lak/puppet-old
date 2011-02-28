require 'puppet/application'

class Puppet::Application::Compiler < Puppet::Application
  should_parse_config
  run_mode :master

  option("--debug", "-d")
  option("--verbose", "-v")

  option("--compile_terminus terminus",  "-t term") do |arg|
    options[:compile_terminus] = arg
  end

  option("--queue_terminus terminus",  "-q term") do |arg|
    options[:queue_terminus] = arg
  end

  attr_accessor :request_queue, :response_queue, :queue_client

  def preinit
    trap(:INT) do
      $stderr.puts "Cancelling startup"
      exit(0)
    end

    # Create this first-off, so we have ARGV
    require 'puppet/daemon'
    @daemon = Puppet::Daemon.new
    @daemon.argv = ARGV.dup
  end

  def run_command
    process_queue
  end

  def execute_request(request)
    begin
      catalog = Puppet::Resource::Catalog.indirection.terminus(options[:compile_terminus]).find(request)
    rescue => detail
      puts detail.backtrace if Puppet[:trace]
      Puppet.err "Could not retrieve catalog for #{request.key}: #{detail}"
      queue_client.publish(response_queue, "Error: #{detail}")
    end

    if catalog
      catalog.extend(Puppet::Indirector::Envelope)
      catalog.request_id = request.request_id

      save(request, catalog)
    end
  end

  def process_queue
    require 'etc'
    require 'puppet/file_serving/content'
    require 'puppet/file_serving/metadata'

    if Puppet.features.root?
      begin
        Puppet::Util.chuser
      rescue => detail
        puts detail.backtrace if Puppet[:trace]
        $stderr.puts "Could not change user to #{Puppet[:user]}: #{detail}"
        exit(39)
      end
    end

    @daemon.daemonize if Puppet[:daemonize]

    Puppet.notice "Starting Puppet compiler daemon version #{Puppet.version}"

    queue = Puppet::Resource::Catalog.indirection.terminus.request_queue

    queue_client.subscribe(queue) do |pson|
      begin
        # We've received a serialized request object
        request = Puppet::Indirector::Request.convert_from(:pson, pson)
        benchmark :notice, "Queued catalog for #{request.key}" do
          execute_request(request)
        end
      rescue => detail
        puts detail.backtrace if Puppet[:trace]
        Puppet.err detail
      end
    end
    Thread.list.each { |thread| thread.join }
  end

  def setup
    options[:compile_terminus] ||= :compiler
    options[:queue_terminus] ||= :queue

    Puppet::Resource::Catalog.indirection.terminus(options[:compile_terminus])

    # Handle the logging settings.
    if options[:debug] or options[:verbose]
      if options[:debug]
        Puppet::Util::Log.level = :debug
      else
        Puppet::Util::Log.level = :info
      end

    end

    unless Puppet[:daemonize]
      Puppet::Util::Log.newdestination(:console)
      options[:setdest] = true
    end

    Puppet[:catalog_terminus] = :queue

    Puppet::Util::Log.newdestination(:syslog) unless options[:setdest]

    exit(Puppet.settings.print_configs ? 0 : 1) if Puppet.settings.print_configs?

    Puppet.settings.use :main, :master, :ssl

    # Cache our nodes in yaml.  Currently not configurable.
    Puppet::Node.indirection.cache_class = :yaml

    # Configure all of the SSL stuff.
    if Puppet::SSL::CertificateAuthority.ca?
      Puppet::SSL::Host.ca_location = :local
      Puppet.settings.use :ca
      Puppet::SSL::CertificateAuthority.instance
    else
      Puppet::SSL::Host.ca_location = :none
    end

    # And now configure our server to *only* hit the CA for data, because that's
    # all it will have write access to.
    Puppet::SSL::Host.ca_location = :only if Puppet::SSL::CertificateAuthority.ca?

    # Make sure we've got a localhost ssl cert
    Puppet::SSL::Host.localhost

    @request_queue = Puppet::Resource::Catalog.indirection.terminus(:queue).request_queue
    @response_queue = Puppet::Resource::Catalog.indirection.terminus(:queue).response_queue
    @queue_client = Puppet::Resource::Catalog.indirection.terminus.client
  end

  def save(request, instance)
      result = nil
      benchmark :info, "Queued catalog for '#{request.key}'" do
        result = queue_client.publish(response_queue, instance.render(:pson))
      end
      result
  rescue => detail
      puts detail.backtrace if Puppet[:trace]
      raise Puppet::Error, "Could not write #{request.key} to queue: #{detail}\nInstance::#{request.instance}\n client : #{queue_client}"
  end
end
