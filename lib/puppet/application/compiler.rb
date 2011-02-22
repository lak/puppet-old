require 'puppet/application'

class Puppet::Application::Compiler < Puppet::Application

  should_parse_config
  run_mode :master

  option("--debug", "-d")
  option("--verbose", "-v")

  # internal option, only to be used by ext/rack/config.ru
  option("--rack")

  option("--compile host",  "-c host") do |arg|
    options[:node] = arg
  end

  option("--logdest DEST",  "-l DEST") do |arg|
    begin
      Puppet::Util::Log.newdestination(arg)
      options[:setdest] = true
    rescue => detail
      puts detail.backtrace if Puppet[:debug]
      $stderr.puts detail.to_s
    end
  end

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
    if options[:node]
      compile
    elsif Puppet[:parseonly]
      parseonly
    else
      main
    end
  end

  def compile
    Puppet::Util::Log.newdestination :console
    raise ArgumentError, "Cannot render compiled catalogs without pson support" unless Puppet.features.pson?
    begin
      unless catalog = Puppet::Resource::Catalog.find(options[:node])
        raise "Could not compile catalog for #{options[:node]}"
      end

      jj catalog.to_resource
    rescue => detail
      $stderr.puts detail
      exit(30)
    end
    exit(0)
  end

  def execute_request(request)
    Puppet.warning "Trying to execute request for #{request}"

    catalog = Puppet::Resource::Catalog.indirection.terminus(:compiler).find(request)

    catalog.extend(Puppet::Indirector::Envelope)
    catalog.request_id = request.request_id

    # This needs to go to the queue for this system to work.
    Puppet::Resource::Catalog.indirection.save(catalog)
  end

  def main
    require 'etc'
    require 'puppet/file_serving/content'
    require 'puppet/file_serving/metadata'

    # Make sure we've got a localhost ssl cert
    Puppet::SSL::Host.localhost

    # And now configure our server to *only* hit the CA for data, because that's
    # all it will have write access to.
    Puppet::SSL::Host.ca_location = :only if Puppet::SSL::CertificateAuthority.ca?

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

    Puppet::Resource::Catalog.indirection.terminus.client.subscribe(queue) do |pson|
      begin
        # We've received a serialized request object
        request = Puppet::Indirector::Request.convert_from(:pson, pson)
        execute_request(request)
      rescue => detail
        puts detail.backtrace if Puppet[:trace]
        Puppet.err detail
      end
    end
    Thread.list.each { |thread| thread.join }
  end

  def setup
    # Handle the logging settings.
    if options[:debug] or options[:verbose]
      if options[:debug]
        Puppet::Util::Log.level = :debug
      else
        Puppet::Util::Log.level = :info
      end

      unless Puppet[:daemonize] or options[:rack]
        Puppet::Util::Log.newdestination(:console)
        options[:setdest] = true
      end
    end

    Puppet[:facts_terminus] = :yaml
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
  end
end
