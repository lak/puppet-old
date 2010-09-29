require 'puppet/util'
require 'puppet/indirector/request'

class Puppet::Util::LastKnownGood
  include Puppet::Indirector::Request::RequestHelper
  attr_accessor :cache
  def initialize(klass, cache = nil)
    @klass = klass
    @cache = cache
  end

  def find(*args)
    request = request(*args)

    begin
      if result = find_in_cache(request)
        return result
      end
    rescue => detail
      puts detail.backtrace if Puppet[:trace]
      Puppet.err "Cached #{self.name} for #{request.key} failed: #{detail}"
    end

    klass.find(request)
  end

  def find_in_cache(*args)
    request = request(*args)
    return nil if request.ignore_cache?
    # See if our instance is in the cache and up to date.
    return nil unless cached = cache.find(request)

    if cached.expired?
      Puppet.info "Not using expired #{self.name} for #{request.key} from cache; expired at #{cached.expiration}"
      return nil
    end

    Puppet.debug "Using cached #{self.name} for #{request.key}"
    cached
  end

  # Remove something via the terminus.
  def destroy(request)
    if cache? and cached = cache.find(request(:find, key, *args))
      # Reuse the existing request, since it's equivalent.
      cache.destroy(request)
    end

    klass.destroy(request)
  end

  # Search for more than one instance.  Should always return an array.
  def search(request)
    klass.search(request)
  end

  # Save the instance in the appropriate terminus.  This method is
  # normally an instance method on the indirected class.
  def save(request)
    if result = klass.save(request)
      request = request.dup
      request.instance = result
      cache.save(request)
    end
    result
  end
end
