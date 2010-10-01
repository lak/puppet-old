require 'puppet/indirector'

class Puppet::Indirector::Route
  # This can be used to select the terminus class.
  attr_accessor :terminus_setting

  attr_reader :indirection_name

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

  def initialize(indirection, terminus_class = nil, cache_class = nil)
    # Store a weak reference
    if indirection.is_a?(Puppet::Indirector::Indirection)
      @indirection_name = indirection.name
    else
      @indirection_name = indirection
    end
    @terminus_class, @cache_class = terminus_class, cache_class
  end

  # Expire a cached object, if one is cached.  Note that we don't actually
  # remove it, we expire it and write it back out to disk.  This way people
  # can still use the expired object if they want.
  def expire(key, *args)
    request = request(:expire, key, *args)

    return nil unless cache?

    return nil unless instance = cache.find(request(:find, key, *args))

    Puppet.info "Expiring the #{indirection_name} cache of #{instance.name}"

    # Set an expiration date in the past
    instance.expiration = Time.now - 60

    cache.save(request(:save, instance, *args))
  end

  def indirection
    Puppet::Indirector::Indirection.instance(indirection_name)
  end

  # Search for an instance in the appropriate terminus, caching the
  # results if caching is configured..
  def find(key, *args)
    request = request(:find, key, *args)
    terminus = prepare(request)

    begin
      if result = find_in_cache(request)
        return result
      end
    rescue => detail
      puts detail.backtrace if Puppet[:trace]
      Puppet.err "Cached #{indirection_name} for #{request.key} failed: #{detail}"
    end

    # Otherwise, return the result from the terminus, caching if appropriate.
    if ! request.ignore_terminus? and result = terminus.find(request)
      result.expiration ||= indirection.expiration
      if cache? and request.use_cache?
        Puppet.info "Caching #{indirection_name} for #{request.key}"
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
      Puppet.info "Not using expired #{indirection_name} for #{request.key} from cache; expired at #{cached.expiration}"
      return nil
    end

    Puppet.debug "Using cached #{indirection_name} for #{request.key}"
    cached
  end

  # Remove something via the terminus.
  def destroy(key, *args)
    request = request(:destroy, key, *args)
    terminus = prepare(request)

    result = terminus.destroy(request)

    if cache? and cached = cache.find(request(:find, key, *args))
      # Reuse the existing request, since it's equivalent.
      cache.destroy(request)
    end

    result
  end

  # Search for more than one instance.  Should always return an array.
  def search(key, *args)
    request = request(:search, key, *args)
    terminus = prepare(request)

    if result = terminus.search(request)
      raise Puppet::DevError, "Search results from terminus #{terminus.name} are not an array" unless result.is_a?(Array)
      result.each do |instance|
        instance.expiration ||= indirection.expiration
      end
      return result
    end
  end

  # Save the instance in the appropriate terminus.  This method is
  # normally an instance method on the indirected class.
  def save(key, instance = nil)
    request = request(:save, key, instance)
    terminus = prepare(request)

    result = terminus.save(request)

    # If caching is enabled, save our document there
    cache.save(request) if cache?

    result
  end

  # Set up our request object.
  def request(*args)
    Puppet::Indirector::Request.new(indirection_name, *args)
  end

  def terminus
    indirection.terminus(terminus_name)
  end

  # Determine the terminus class.
  def terminus_class
    unless @terminus_class
      if setting = self.terminus_setting
        self.terminus_class = Puppet.settings[setting].to_sym
      else
        raise Puppet::DevError, "No terminus class nor terminus setting was provided for indirection #{indirection_name}"
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
    unless Puppet::Indirector::Terminus.terminus_class(indirection_name, terminus_class)
      raise ArgumentError, "Could not find terminus #{terminus_class} for indirection #{indirection_name}"
    end
  end

  private

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

    dest_terminus = indirection.terminus(terminus_name)
    check_authorization(request, dest_terminus)

    dest_terminus
  end
end
