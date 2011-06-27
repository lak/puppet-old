require 'puppet/util'
require 'puppet/util/log'
require 'puppet/util/metric'
require 'puppet/util/autoload'

class Puppet::Type
  extend Puppet::Util # for symbolize()
  extend Puppet::Util::MethodHelper # for symbolize_options()
  # remove all type instances; this is mostly only useful for testing
  def self.allclear
    @types.each { |name, type|
      type.clear
    }
  end

  # iterate across all of the subclasses of Type
  def self.eachtype
    @types.each do |name, type|
      yield type
    end
  end

  # Load all types.  Only currently used for documentation.
  def self.loadall
    typeloader.loadall
  end

  # Define a new type.
  def self.newtype(name, options = {}, &block)
    # Handle backward compatibility
    unless options.is_a?(Hash)
      Puppet.warning "Puppet::Type.newtype(#{name}) now expects a hash as the second argument, not #{options.inspect}"
      options = {:parent => options}
    end

    # First make sure we don't have a method sitting around
    name = symbolize(name)
    newmethod = "new#{name.to_s}"

    # Used for method manipulation.
    selfobj = singleton_class

    @types ||= {}

    if @types.include?(name)
      if self.respond_to?(newmethod)
        # Remove the old newmethod
        selfobj.send(:remove_method,newmethod)
      end
    end

    options = symbolize_options(options)

    if parent = options[:parent]
      options.delete(:parent)
    end

    # Then create the instance
    klass = parent || Puppet::Resource::Type
    type = klass.new(:definition, name)

    # XXX This will overwrite
    @types[type.name.to_s.downcase.to_sym] = type

    type.instance_eval(&block)

    # Now define a "new<type>" method for convenience.
    if respond_to? newmethod
      # Refuse to overwrite existing methods like 'newparam' or 'newtype'.
      Puppet.warning "'new#{name.to_s}' method already exists; skipping"
    else
      selfobj.send(:define_method, newmethod) do |*args|
        raise "new<type> doesn't work yet..."
        type.new(*args)
      end
    end

    # If they've got all the necessary methods defined and they haven't
    # already added the property, then do so now.
    type.ensurable if type.ensurable? and ! type.validproperty?(:ensure)

    # Now set up autoload any providers that might exist for this type.

    type.providerloader = Puppet::Util::Autoload.new(
      type,
      "puppet/provider/#{type.name.to_s}"
    )

    # We have to load everything so that we can figure out the default type.
    type.providerloader.loadall

    type
  end

  # Remove an existing defined type.  Largely used for testing.
  def self.rmtype(name)
    klass = rmclass(
      name,
      :hash => @types
    )

    singleton_class.send(:remove_method, "new#{name}") if respond_to?("new#{name}")
  end

  # Return a Type instance by name.
  def self.type(name)
    @types ||= {}

    name = name.to_s.downcase.to_sym

    if t = @types[name]
      return t
    else
      if typeloader.load(name)
        Puppet.warning "Loaded puppet/type/#{name} but no class was created" unless @types.include? name
      end

      return @types[name]
    end
  end

  # Create a loader for Puppet types.
  def self.typeloader
    unless defined?(@typeloader)
      @typeloader = Puppet::Util::Autoload.new(
        self,
        "puppet/type", :wrap => false
      )
    end

    @typeloader
  end

  # This is a class-level cache so we can reload the
  # types without losing the list of providers.
  def self.provider_hash_by_type(type)
    @provider_hashes ||= {}
    @provider_hashes[type] ||= {}
  end
end

require 'puppet/resource/type'
require 'puppet/oldresource'
