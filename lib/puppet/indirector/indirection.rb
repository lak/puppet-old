require 'puppet/util/docs'
require 'puppet/indirector/envelope'
require 'puppet/indirector/request'
require 'puppet/util/cacher'
require 'puppet/util/queue'

# The class that connects functional classes with their different collection
# back-ends.  Each indirection has a set of associated terminus classes,
# each of which is a subclass of Puppet::Indirector::Terminus.
class Puppet::Indirector::Indirection
  include Puppet::Util::Cacher
  include Puppet::Util::Docs
  include Puppet::Util::Queue
  include Puppet::Util

  @@indirections = []

  # Find an indirection by name.  This is provided so that Terminus classes
  # can specifically hook up with the indirections they are associated with.
  def self.instance(name)
    @@indirections.find { |i| i.name == name }
  end

  # Return a list of all known indirections.  Used to generate the
  # reference.
  def self.instances
    @@indirections.collect { |i| i.name }
  end

  # Find an indirected model by name.  This is provided so that Terminus classes
  # can specifically hook up with the indirections they are associated with.
  def self.model(name)
    return nil unless match = @@indirections.find { |i| i.name == name }
    match.model
  end

  attr_accessor :name, :model

  # Create and return our cache terminus.
  def cache
    raise(Puppet::DevError, "Tried to cache when no cache class was set") unless cache_class
    terminus(cache_class)
  end

  # Should we use a cache?
  def cache?
    cache_class ? true : false
  end

  attr_reader :cache_class
  # Define a terminus class to be used for caching.
  def cache_class=(class_name)
    validate_terminus_class(class_name) if class_name
    @cache_class = class_name
  end

  # This is only used for testing.
  def delete
    @@indirections.delete(self) if @@indirections.include?(self)
  end

  # Set the time-to-live for instances created through this indirection.
  def ttl=(value)
    raise ArgumentError, "Indirection TTL must be an integer" unless value.is_a?(Fixnum)
    @ttl = value
  end

  # Default to the runinterval for the ttl.
  def ttl
    @ttl ||= Puppet[:runinterval].to_i
  end

  # Calculate the expiration date for a returned instance.
  def expiration
    Time.now + ttl
  end

  # Generate the full doc string.
  def doc
    text = ""

    text += scrub(@doc) + "\n\n" if @doc

    if s = terminus_setting
      text += "* **Terminus Setting**: #{terminus_setting}"
    end

    text
  end

  def initialize(model, name, options = {})
    @model = model
    @name = name

    @cache_class = nil
    @terminus_class = nil

    @queue = []
    @responses = {}

    raise(ArgumentError, "Indirection #{@name} is already defined") if @@indirections.find { |i| i.name == @name }
    @@indirections << self

    if mod = options[:extend]
      extend(mod)
      options.delete(:extend)
    end

    # This is currently only used for cache_class and terminus_class.
    options.each do |name, value|
      begin
        send(name.to_s + "=", value)
      rescue NoMethodError
        raise ArgumentError, "#{name} is not a valid Indirection parameter"
      end
    end

    look_for_requests()
  end

  # Set up our request object.
  def request(*args)
    Puppet::Indirector::Request.new(self.name, *args)
  end

  # Return the singleton terminus for this indirection.
  def terminus(terminus_name = nil)
    # Get the name of the terminus.
    raise Puppet::DevError, "No terminus specified for #{self.name}; cannot redirect" unless terminus_name ||= terminus_class

    termini[terminus_name] ||= make_terminus(terminus_name)
  end

  # This can be used to select the terminus class.
  attr_accessor :terminus_setting

  # Determine the terminus class.
  def terminus_class
    unless @terminus_class
      if setting = self.terminus_setting
        self.terminus_class = Puppet.settings[setting].to_sym
      else
        raise Puppet::DevError, "No terminus class nor terminus setting was provided for indirection #{self.name}"
      end
    end
    @terminus_class
  end

  def reset_terminus_class
    @terminus_class = nil
  end

  # Specify the terminus class to use.
  def terminus_class=(klass)
    validate_terminus_class(klass)
    @terminus_class = klass
  end

  # This is used by terminus_class= and cache=.
  def validate_terminus_class(terminus_class)
    raise ArgumentError, "Invalid terminus name #{terminus_class.inspect}" unless terminus_class and terminus_class.to_s != ""
    unless Puppet::Indirector::Terminus.terminus_class(self.name, terminus_class)
      raise ArgumentError, "Could not find terminus #{terminus_class} for indirection #{self.name}"
    end
  end

  # Expire a cached object, if one is cached.  Note that we don't actually
  # remove it, we expire it and write it back out to disk.  This way people
  # can still use the expired object if they want.
  def expire(key, *args)
    request = request(:expire, key, *args)

    return nil unless cache?

    return nil unless instance = cache.find(request(:find, key, *args))

    Puppet.info "Expiring the #{self.name} cache of #{instance.name}"

    # Set an expiration date in the past
    instance.expiration = Time.now - 60

    cache.save(request(:save, instance, *args))
  end

  # Search for an instance in the appropriate terminus, caching the
  # results if caching is configured..
  def find(key, *args)
    handle_request(:find, key, *args)
  end

  # Remove something via the terminus.
  def destroy(key, *args)
    handle_request(:destroy, key, *args)
  end

  # Search for more than one instance.  Should always return an array.
  def search(key, *args)
    handle_request(:search, key, *args)
  end

  # Save the instance in the appropriate terminus.  This method is
  # normally an instance method on the indirected class.
  def save(key, instance = nil)
    handle_request(:save, key, instance)
  end

  def queue_per_request?
    true
  end

  def queue
    queue_name "puppet", name
  end

  def response_queue
    queue_name "puppet", name, :response
  end

  # Search for an instance in the appropriate terminus, caching the
  # results if caching is configured..
  def old_find(request)
    terminus = prepare(request)

    begin
      if result = find_in_cache(request)
        return result
      end
    rescue => detail
      puts detail.backtrace if Puppet[:trace]
      Puppet.err "Cached #{self.name} for #{request.key} failed: #{detail}"
    end

    # Otherwise, return the result from the terminus, caching if appropriate.
    if ! request.ignore_terminus? and result = terminus.find(request)
      result.expiration ||= self.expiration
      if cache? and request.use_cache?
        Puppet.info "Caching #{self.name} for #{request.key}"
        cache.save request(:save, result, *args)
      end

      return terminus.respond_to?(:filter) ? terminus.filter(result) : result
    end

    nil
  end

  def find_in_cache(request)
    # See if our instance is in the cache and up to date.
    return nil unless cache? and ! request.ignore_cache? and cached = cache.find(request)
    if cached.expired?
      Puppet.info "Not using expired #{self.name} for #{request.key} from cache; expired at #{cached.expiration}"
      return nil
    end

    Puppet.debug "Using cached #{self.name} for #{request.key}"
    cached
  end

  # Remove something via the terminus.
  def old_destroy(request)
    terminus = prepare(request)

    result = terminus.destroy(request)

    if cache? and cached = cache.find(request(:find, key, *args))
      # Reuse the existing request, since it's equivalent.
      cache.destroy(request)
    end

    result
  end

  # Search for more than one instance.  Should always return an array.
  def old_search(request)
    terminus = prepare(request)

    if result = terminus.search(request)
      raise Puppet::DevError, "Search results from terminus #{terminus.name} are not an array" unless result.is_a?(Array)
      result.each do |instance|
        instance.expiration ||= self.expiration
      end
      return result
    end
  end

  # Save the instance in the appropriate terminus.  This method is
  # normally an instance method on the indirected class.
  def old_save(request)
    terminus = prepare(request)

    result = terminus.save(request)

    # If caching is enabled, save our document there
    cache.save(request) if cache?

    result
  end

  private

  def queue_client
    @queue_client ||= client_class.new
  end

  def queue_name(*ary)
    ary.collect { |i| i.to_s }.join(".")
  end

  def request_expired?(request)
    request.start ||= Time.now

    return (Time.now - request.start).to_i > 100
    #return (Time.now - request.start).to_i > request.ttl
  end

  def handle_request(method, key, *args)
    request = request(method, key, *args)

    queue_request(request)

    sync_look_for_response(request)
  end

  def look_for_requests
    #Puppet.err "Subscribing to #{queue} for #{name}"
    queue_client.subscribe(queue) do |pson|
      request = Puppet::Indirector::Request.convert_from(:pson, pson)
      benchmark :notice, "Processed request #{request}" do
        process_request(request)
      end
    end
  end

  def sync_look_for_response(request)
    # Set up the callback for processing requests.
    result = nil
    queue_client.subscribe(response_queue) do |pson|
      begin
        result = model.convert_from(:pson, pson)
      rescue => details
        puts details.backtrace
        Puppet.warning "Failed to convert pson to #{name}: #{details}"
      end
    end

    until request_expired?(request)
      break if result
      Puppet.debug "Sleeping for result from #{request}/#{request.object_id}"
      sleep 0.1
    end

    raise "Response from #{request} timed out" unless result

    if result.request_id.nil?
      #Puppet.warning "No request ID for instance of #{model}"
      return result
    end

    if result.request_id != request.object_id
      raise "Got wrong response for #{request}: #{result.request_id} vs #{request.object_id}"
    end

    result
  end

  def queue_request(request)
    benchmark :info, "Queued request #{request} to #{queue}" do
      queue_client.publish(queue, request.render(:pson))
    end
  end

  def process_request(request)
    unless result = request.execute(self)
      raise "Could not get result from #{request}"
    end
    result.request_id = request.object_id

    benchmark :info, "Queued response for #{request} to #{response_queue}" do
      queue_client.publish(response_queue, result.render(:pson))
    end
  rescue => details
    puts details.backtrace
    # do something with exceptions
    Puppet.err "Something failed! #{details}"
  end

  # Check authorization if there's a hook available; fail if there is one
  # and it returns false.
  def check_authorization(request, terminus)
    # At this point, we're assuming authorization makes no sense without
    # client information.
    return unless request.node

    # This is only to authorize via a terminus-specific authorization hook.
    return unless terminus.respond_to?(:authorized?)

    unless terminus.authorized?(request)
      msg = "Not authorized to call #{request.method} on #{request}"
      msg += " with #{request.options.inspect}" unless request.options.empty?
      raise ArgumentError, msg
    end
  end

  # Setup a request, pick the appropriate terminus, check the request's authorization, and return it.
  def prepare(request)
    # Pick our terminus.
    if respond_to?(:select_terminus)
      unless terminus_name = select_terminus(request)
        raise ArgumentError, "Could not determine appropriate terminus for #{request}"
      end
    else
      terminus_name = terminus_class
    end

    dest_terminus = terminus(terminus_name)
    check_authorization(request, dest_terminus)

    dest_terminus
  end

  # Create a new terminus instance.
  def make_terminus(terminus_class)
    # Load our terminus class.
    unless klass = Puppet::Indirector::Terminus.terminus_class(self.name, terminus_class)
      raise ArgumentError, "Could not find terminus #{terminus_class} for indirection #{self.name}"
    end
    klass.new
  end

  def sync
    Puppet::Util.sync(name).synchronize(Sync::EX) { yield }
  end

  # Cache our terminus instances indefinitely, but make it easy to clean them up.
  cached_attr(:termini) { Hash.new }
end
