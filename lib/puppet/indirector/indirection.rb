require 'puppet/util/docs'
require 'puppet/indirector/envelope'
require 'puppet/indirector/request'
require 'puppet/indirector/route'
require 'puppet/util/cacher'

# The class that connects functional classes with their different collection
# back-ends.  Each indirection has a set of associated terminus classes,
# each of which is a subclass of Puppet::Indirector::Terminus.
class Puppet::Indirector::Indirection
  include Puppet::Util::Cacher
  include Puppet::Util::Docs

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
  attr_reader :default_route

  [:find, :save, :search, :destroy, :terminus, :cache, :terminus_class, :terminus_class=, :cache_class=, :cache_class].each do |method|
    define_method(method) do |*args|
      Puppet.warning "#{model}.indirection.#{method} is deprecated - use #{model}.default_route.#{method}"
      default_route.send(method, *args)
    end
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

    raise(ArgumentError, "Indirection #{@name} is already defined") if @@indirections.find { |i| i.name == @name }
    @@indirections << self

    if mod = options[:extend]
      extend(mod)
      options.delete(:extend)
    end

    # This has to happen after we add ourselves to the indirections list,
    # because that list is used for validation.
    @default_route = Puppet::Indirector::Route.new(self)
    [:terminus_setting, :terminus_class, :cache_class].each do |setting|
      if value = options[setting]
        options.delete(setting)
        @default_route.send(setting.to_s + "=", value)
      end
    end

    # This is currently only used for cache_class and terminus_class.
    options.each do |name, value|
      begin
        send(name.to_s + "=", value)
      rescue NoMethodError
        raise ArgumentError, "#{name} is not a valid Indirection parameter"
      end
    end
  end

  # Return the singleton terminus for this indirection.
  def terminus(terminus_name)
    # Get the name of the terminus.
    raise Puppet::DevError, "No terminus specified for #{self.name}; cannot redirect" unless terminus_name

    termini[terminus_name] ||= make_terminus(terminus_name)
  end

  private

  # Create a new terminus instance.
  def make_terminus(terminus_class)
    # Load our terminus class.
    unless klass = Puppet::Indirector::Terminus.terminus_class(self.name, terminus_class)
      raise ArgumentError, "Could not find terminus #{terminus_class} for indirection #{self.name}"
    end
    klass.new
  end

  # Cache our terminus instances indefinitely, but make it easy to clean them up.
  cached_attr(:termini) { Hash.new }
end
