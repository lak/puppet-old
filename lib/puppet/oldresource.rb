require 'puppet/util'
require 'puppet/util/tagging'
require 'puppet/property'
require 'puppet/parameter'
require 'puppet/util/errors'
require 'puppet/util/logging'
require 'puppet/util/log_paths'
require 'puppet/file_collection/lookup'

# This class is essentially the instance
# functionality of the old Puppet::Type class.
class Puppet::OldResource
  include Puppet::Util
  include Puppet::Util::Errors
  include Puppet::Util::LogPaths
  include Puppet::Util::Tagging
  include Puppet::Util::Logging
  include Puppet::FileCollection::Lookup

  def apply
    unless @catalog
      @catalog = Puppet::Resource::Catalog.new
      @catalog.add_resource(self)
    end
    catalog.apply
  end

  # Return either the attribute alias or the attribute.
  def attr_alias(name)
    name = symbolize(name)
    if synonym = resource_type.attr_alias(name)
      return synonym
    else
      return name
    end
  end

  # Are we deleting this resource?
  def deleting?
    obj = @parameters[:ensure] and obj.should == :absent
  end

  # Create a new property if it is valid but doesn't exist
  # Returns: true if a new parameter was added, false otherwise
  def add_property_parameter(prop_name)
    if resource_type.validproperty?(prop_name) && !@parameters[prop_name]
      self.newattr(prop_name)
      return true
    end
    false
  end

  #
  # The name_var is the key_attribute in the case that there is only one.
  #
  def name_var
    key_attributes = resource_type.key_attributes
    (key_attributes.length == 1) && key_attributes.first
  end

  # abstract accessing parameters and properties, and normalize
  # access to always be symbols, not strings
  # This returns a value, not an object.  It returns the 'is'
  # value, but you can also specifically return 'is' and 'should'
  # values using 'object.is(:property)' or 'object.should(:property)'.
  def [](name)
    name = attr_alias(name)

    fail("Invalid parameter #{name}(#{name.inspect})") unless resource_type.valid_parameter?(name)

    if name == :name && nv = name_var
      name = nv
    end

    if obj = @parameters[name]
      # Note that if this is a property, then the value is the "should" value,
      # not the current value.
      obj.value
    else
      return nil
    end
  end

  # Abstract setting parameters and properties, and normalize
  # access to always be symbols, not strings.  This sets the 'should'
  # value on properties, and otherwise just sets the appropriate parameter.
  def []=(name,value)
    name = attr_alias(name)

    fail("Invalid parameter #{name}") unless resource_type.valid_parameter?(name)

    if name == :name && nv = name_var
      name = nv
    end
    raise Puppet::Error.new("Got nil value for #{name}") if value.nil?

    property = self.newattr(name)

    if property
      begin
        # make sure the parameter doesn't have any errors
        property.value = value
      rescue => detail
        error = Puppet::Error.new("Parameter #{name} failed: #{detail}")
        error.set_backtrace(detail.backtrace)
        raise error
      end
    end

    nil
  end

  # remove a property from the object; useful in testing or in cleanup
  # when an error has been encountered
  def delete(attr)
    attr = symbolize(attr)
    if @parameters.has_key?(attr)
      @parameters.delete(attr)
    else
      raise Puppet::DevError.new("Undefined attribute '#{attr}' in #{self}")
    end
  end

  # iterate across the existing properties
  def eachproperty
    # properties is a private method
    properties.each { |property|
      yield property
    }
  end

  # Create a transaction event.  Called by Transaction or by
  # a property.
  def event(options = {})
    Puppet::Transaction::Event.new({:resource => self, :file => file, :line => line, :tags => tags}.merge(options))
  end

  # Let the catalog determine whether a given cached value is
  # still valid or has expired.
  def expirer
    catalog
  end

  # retrieve the 'should' value for a specified property
  def should(name)
    name = attr_alias(name)
    (prop = @parameters[name] and prop.is_a?(Puppet::Property)) ? prop.should : nil
  end

  # Create the actual attribute instance.  Requires either the attribute
  # name or class as the first argument, then an optional hash of
  # attributes to set during initialization.
  def newattr(name)
    if name.is_a?(Class)
      klass = name
      name = klass.name
    end

    unless klass = resource_type.attrclass(name)
      raise Puppet::Error, "Resource type #{resource_type.name} does not support parameter #{name}"
    end

    if provider and ! provider.class.supports_parameter?(klass)
      missing = klass.required_features.find_all { |f| ! provider.class.feature?(f) }
      info "Provider %s does not support features %s; not managing attribute %s" % [provider.class.name, missing.join(", "), name]
      return nil
    end

    return @parameters[name] if @parameters.include?(name)

    @parameters[name] = klass.new(:resource => self)
  end

  # return the value of a parameter
  def parameter(name)
    @parameters[name.to_sym]
  end

  def parameters
    @parameters.dup
  end

  # Is the named property defined?
  def propertydefined?(name)
    name = name.intern unless name.is_a? Symbol
    @parameters.include?(name)
  end

  # Return an actual property instance by name; to return the value, use 'resource[param]'
  # LAK:NOTE(20081028) Since the 'parameter' method is now a superset of this method,
  # this one should probably go away at some point.
  def property(name)
    (obj = @parameters[symbolize(name)] and obj.is_a?(Puppet::Property)) ? obj : nil
  end

  # For any parameters or properties that have defaults and have not yet been
  # set, set them now.  This method can be handed a list of attributes,
  # and if so it will only set defaults for those attributes.
  def set_default(attr)
    return unless klass = resource_type.attrclass(attr)
    return unless klass.method_defined?(:default)
    return if @parameters.include?(klass.name)

    return unless parameter = newattr(klass.name)

    if value = parameter.default and ! value.nil?
      parameter.value = value
    else
      @parameters.delete(parameter.name)
    end
  end

  # Convert our object to a hash.  This just includes properties.
  def to_hash
    rethash = {}

    @parameters.each do |name, obj|
      rethash[name] = obj.value
    end

    rethash
  end

  def type
    resource_type.name
  end

  # Return a specific value for an attribute.
  def value(name)
    name = attr_alias(name)

    (obj = @parameters[name] and obj.respond_to?(:value)) ? obj.value : nil
  end

  def version
    return 0 unless catalog
    catalog.version
  end

  # Return all of the property objects, in the order specified in the
  # class.
  def properties
    resource_type.properties.collect { |prop| @parameters[prop.name] }.compact
  end

  # Is this type's name isomorphic with the object?  That is, if the
  # name conflicts, does it necessarily mean that the objects conflict?
  # Defaults to true.
  def self.isomorphic?
    if defined?(@isomorphic)
      return @isomorphic
    else
      return true
    end
  end

  def isomorphic?
    resource_type.isomorphic?
  end

  # is the instance a managed instance?  A 'yes' here means that
  # the instance was created from the language, vs. being created
  # in order resolve other questions, such as finding a package
  # in a list
  def managed?
    # Once an object is managed, it always stays managed; but an object
    # that is listed as unmanaged might become managed later in the process,
    # so we have to check that every time
    if @managed
      return @managed
    else
      @managed = false
      properties.each { |property|
        s = property.should
        if s and ! property.class.unmanaged
          @managed = true
          break
        end
      }
      return @managed
    end
  end

  ###############################
  # Code related to the container behaviour.

  def depthfirst?
    false
  end

  # Remove an object.  The argument determines whether the object's
  # subscriptions get eliminated, too.
  def remove(rmdeps = true)
    # This is hackish (mmm, cut and paste), but it works for now, and it's
    # better than warnings.
    @parameters.each do |name, obj|
      obj.remove
    end
    @parameters.clear

    @parent = nil

    # Remove the reference to the provider.
    if self.provider
      @provider.clear
      @provider = nil
    end
  end

  ###############################
  # Code related to evaluating the resources.

  # Flush the provider, if it supports it.  This is called by the
  # transaction.
  def flush
    self.provider.flush if self.provider and self.provider.respond_to?(:flush)
  end

  # if all contained objects are in sync, then we're in sync
  # FIXME I don't think this is used on the type instances any more,
  # it's really only used for testing
  def insync?(is)
    insync = true

    if property = @parameters[:ensure]
      unless is.include? property
        raise Puppet::DevError,
          "The is value is not in the is array for '#{property.name}'"
      end
      ensureis = is[property]
      if property.safe_insync?(ensureis) and property.should == :absent
        return true
      end
    end

    properties.each { |property|
      unless is.include? property
        raise Puppet::DevError,
          "The is value is not in the is array for '#{property.name}'"
      end

      propis = is[property]
      unless property.safe_insync?(propis)
        property.debug("Not in sync: #{propis.inspect} vs #{property.should.inspect}")
        insync = false
      #else
      #    property.debug("In sync")
      end
    }

    #self.debug("#{self} sync status is #{insync}")
    insync
  end

  # retrieve the current value of all contained properties
  def retrieve
    fail "Provider #{provider.class.name} is not functional on this host" if self.provider.is_a?(Puppet::Provider) and ! provider.class.suitable?

    result = Puppet::Resource.new(type, title)

    # Provide the name, so we know we'll always refer to a real thing
    result[:name] = self[:name] unless self[:name] == title

    if ensure_prop = property(:ensure) or (resource_type.valid_parameter?(:ensure) and ensure_prop = newattr(:ensure))
      result[:ensure] = ensure_state = ensure_prop.retrieve
    else
      ensure_state = nil
    end

    properties.each do |property|
      next if property.name == :ensure
      if ensure_state == :absent
        result[property] = :absent
      else
        result[property] = property.retrieve
      end
    end

    result
  end

  def retrieve_resource
    resource = retrieve
    resource = Resource.new(type, title, :parameters => resource) if resource.is_a? Hash
    resource
  end

  # Get a hash of the current properties.  Returns a hash with
  # the actual property instance as the key and the current value
  # as the, um, value.
  def currentpropvalues
    # It's important to use the 'properties' method here, as it follows the order
    # in which they're defined in the class.  It also guarantees that 'ensure'
    # is the first property, which is important for skipping 'retrieve' on
    # all the properties if the resource is absent.
    ensure_state = false
    return properties.inject({}) do | prophash, property|
      if property.name == :ensure
        ensure_state = property.retrieve
        prophash[property] = ensure_state
      else
        if ensure_state == :absent
          prophash[property] = :absent
        else
          prophash[property] = property.retrieve
        end
      end
      prophash
    end
  end

  # Are we running in noop mode?
  def noop?
    # If we're not a host_config, we're almost certainly part of
    # Settings, and we want to ignore 'noop'
    return false if catalog and ! catalog.host_config?

    if defined?(@noop)
      @noop
    else
      Puppet[:noop]
    end
  end

  def noop
    noop?
  end

  def isomorphic?
    resource_type.isomorphic?
  end

  # is the instance a managed instance?  A 'yes' here means that
  # the instance was created from the language, vs. being created
  # in order resolve other questions, such as finding a package
  # in a list
  def managed?
    # Once an object is managed, it always stays managed; but an object
    # that is listed as unmanaged might become managed later in the process,
    # so we have to check that every time
    if @managed
      return @managed
    else
      @managed = false
      properties.each { |property|
        s = property.should
        if s and ! property.class.unmanaged
          @managed = true
          break
        end
      }
      return @managed
    end
  end

  ###############################
  # Code related to the container behaviour.

  def depthfirst?
    false
  end

  # Remove an object.  The argument determines whether the object's
  # subscriptions get eliminated, too.
  def remove(rmdeps = true)
    # This is hackish (mmm, cut and paste), but it works for now, and it's
    # better than warnings.
    @parameters.each do |name, obj|
      obj.remove
    end
    @parameters.clear

    @parent = nil

    # Remove the reference to the provider.
    if self.provider
      @provider.clear
      @provider = nil
    end
  end

  ###############################
  # Code related to evaluating the resources.

  # Flush the provider, if it supports it.  This is called by the
  # transaction.
  def flush
    self.provider.flush if self.provider and self.provider.respond_to?(:flush)
  end

  # if all contained objects are in sync, then we're in sync
  # FIXME I don't think this is used on the type instances any more,
  # it's really only used for testing
  def insync?(is)
    insync = true

    if property = @parameters[:ensure]
      unless is.include? property
        raise Puppet::DevError,
          "The is value is not in the is array for '#{property.name}'"
      end
      ensureis = is[property]
      if property.safe_insync?(ensureis) and property.should == :absent
        return true
      end
    end

    properties.each { |property|
      unless is.include? property
        raise Puppet::DevError,
          "The is value is not in the is array for '#{property.name}'"
      end

      propis = is[property]
      unless property.safe_insync?(propis)
        property.debug("Not in sync: #{propis.inspect} vs #{property.should.inspect}")
        insync = false
      #else
      #    property.debug("In sync")
      end
    }

    #self.debug("#{self} sync status is #{insync}")
    insync
  end

  # retrieve the current value of all contained properties
  def retrieve
    fail "Provider #{provider.class.name} is not functional on this host" if self.provider.is_a?(Puppet::Provider) and ! provider.class.suitable?

    result = Puppet::Resource.new(type, title)

    # Provide the name, so we know we'll always refer to a real thing
    result[:name] = self[:name] unless self[:name] == title

    if ensure_prop = property(:ensure) or (resource_type.valid_parameter?(:ensure) and ensure_prop = newattr(:ensure))
      result[:ensure] = ensure_state = ensure_prop.retrieve
    else
      ensure_state = nil
    end

    properties.each do |property|
      next if property.name == :ensure
      if ensure_state == :absent
        result[property] = :absent
      else
        result[property] = property.retrieve
      end
    end

    result
  end

  def retrieve_resource
    resource = retrieve
    resource = Resource.new(type, title, :parameters => resource) if resource.is_a? Hash
    resource
  end

  # Get a hash of the current properties.  Returns a hash with
  # the actual property instance as the key and the current value
  # as the, um, value.
  def currentpropvalues
    # It's important to use the 'properties' method here, as it follows the order
    # in which they're defined in the class.  It also guarantees that 'ensure'
    # is the first property, which is important for skipping 'retrieve' on
    # all the properties if the resource is absent.
    ensure_state = false
    return properties.inject({}) do | prophash, property|
      if property.name == :ensure
        ensure_state = property.retrieve
        prophash[property] = ensure_state
      else
        if ensure_state == :absent
          prophash[property] = :absent
        else
          prophash[property] = property.retrieve
        end
      end
      prophash
    end
  end

  # Are we running in noop mode?
  def noop?
    # If we're not a host_config, we're almost certainly part of
    # Settings, and we want to ignore 'noop'
    return false if catalog and ! catalog.host_config?

    if defined?(@noop)
      @noop
    else
      Puppet[:noop]
    end
  end

  def noop
    noop?
  end

  # Create the path for logging and such.
  def pathbuilder
    if p = parent
      [p.pathbuilder, self.ref].flatten
    else
      [self.ref]
    end
  end

  # Figure out of there are any objects we can automatically add as
  # dependencies.
  def autorequire(rel_catalog = nil)
    rel_catalog ||= catalog
    raise(Puppet::DevError, "You cannot add relationships without a catalog") unless rel_catalog

    reqs = []
    resource_type.eachautorequire { |type, block|
      # Ignore any types we can't find, although that would be a bit odd.
      next unless typeobj = Puppet::Type.type(type)

      # Retrieve the list of names from the block.
      next unless list = self.instance_eval(&block)
      list = [list] unless list.is_a?(Array)

      # Collect the current prereqs
      list.each { |dep|
        obj = nil
        # Support them passing objects directly, to save some effort.
        unless dep.is_a? Puppet::OldResource
          # Skip autorequires that we aren't managing
          unless dep = rel_catalog.resource(type, dep)
            next
          end
        end

        reqs << Puppet::Relationship.new(dep, self)
      }
    }

    reqs
  end

  # Build the dependencies associated with an individual object.
  def builddepends
    # Handle the requires
    resource_type.class.relationship_params.collect do |klass|
      if param = @parameters[klass.name]
        param.to_edges
      end
    end.flatten.reject { |r| r.nil? }
  end

  # Define the initial list of tags.
  def tags=(list)
    tag(resource_type.name)
    tag(*list)
  end

  # Types (which map to resources in the languages) are entirely composed of
  # attribute value pairs.  Generally, Puppet calls any of these things an
  # 'attribute', but these attributes always take one of three specific
  # forms:  parameters, metaparams, or properties.

  # In naming methods, I have tried to consistently name the method so
  # that it is clear whether it operates on all attributes (thus has 'attr' in
  # the method name, or whether it operates on a specific type of attributes.
  attr_writer :title
  attr_writer :noop

  include Enumerable

  # The catalog that this resource is stored in.
  attr_accessor :catalog

  # is the resource exported
  attr_accessor :exported

  # is the resource virtual (it should not :-))
  attr_accessor :virtual

  # create a log at specified level
  def log(msg)

    Puppet::Util::Log.create(

      :level => @parameters[:loglevel].value,
      :message => msg,

      :source => self
    )
  end


  # instance methods related to instance intrinsics
  # e.g., initialize and name

  public

  attr_reader :original_parameters
  attr_reader :resource_type
  attr_reader :provider

  def provider=(name)
    if name.is_a?(Puppet::Provider)
      @provider = name
      @provider.resource = self
    elsif klass = resource_type.provider(name)
      @provider = klass.new(self)
    else
      raise ArgumentError, "Could not find #{name} provider of #{resource_type.name}"
    end
  end

  def uniqueness_key
    resource_type.key_attributes.sort_by { |attribute_name| attribute_name.to_s }.map{ |attribute_name| self[attribute_name] }
  end

  # initialize the type instance
  def initialize(type, resource)
    @resource_type = type

    extend(Puppet::Resource::Type.metaparam_module)
    extend(type.instance_module)

    raise Puppet::DevError, "Got TransObject instead of Resource or hash" if resource.is_a?(Puppet::TransObject)
    resource = resource_type.hash2resource(resource) unless resource.is_a?(Puppet::Resource)

    # The list of parameter/property instances.
    @parameters = {}

    # Set the title first, so any failures print correctly.
    if resource.type.to_s.downcase.to_sym == resource_type.name
      self.title = resource.title
    else
      # This should only ever happen for components
      self.title = resource.ref
    end

    [:file, :line, :catalog, :exported, :virtual].each do |getter|
      setter = getter.to_s + "="
      if val = resource.send(getter)
        self.send(setter, val)
      end
    end

    @tags = resource.tags

    @original_parameters = resource.to_hash

    set_name(@original_parameters)

    set_default(:provider)

    set_parameters(@original_parameters)

    self.validate if self.respond_to?(:validate)

    post_initialize if respond_to?(:post_initialize)
  end

  private

  # Set our resource's name.
  def set_name(hash)
    self[name_var] = hash.delete(name_var) if name_var
  end

  # Set all of the parameters from a hash, in the appropriate order.
  def set_parameters(hash)
    # Use the order provided by allattrs, but add in any
    # extra attributes from the resource so we get failures
    # on invalid attributes.
    no_values = []
    (resource_type.allattrs + hash.keys).uniq.each do |attr|
      begin
        # Set any defaults immediately.  This is mostly done so
        # that the default provider is available for any other
        # property validation.
        if hash.has_key?(attr)
          self[attr] = hash[attr]
        else
          no_values << attr
        end
      rescue ArgumentError, Puppet::Error, TypeError
        raise
      rescue => detail
        error = Puppet::DevError.new( "Could not set #{attr} on #{resource_type.name}: #{detail}")
        error.set_backtrace(detail.backtrace)
        raise error
      end
    end
    no_values.each do |attr|
      set_default(attr)
    end
  end

  public

  # Set up all of our autorequires.
  def finish
    # Make sure all of our relationships are valid.  Again, must be done
    # when the entire catalog is instantiated.
    resource_type.class.relationship_params.collect do |klass|
      if param = @parameters[klass.name]
        param.validate_relationship
      end
    end.flatten.reject { |r| r.nil? }
  end

  # For now, leave the 'name' method functioning like it used to.  Once 'title'
  # works everywhere, I'll switch it.
  def name
    self[:name]
  end

  # Look up our parent in the catalog, if we have one.
  def parent
    return nil unless catalog

    unless defined?(@parent)
      if parents = catalog.adjacent(self, :direction => :in)
        # We should never have more than one parent, so let's just ignore
        # it if we happen to.
        @parent = parents.shift
      else
        @parent = nil
      end
    end
    @parent
  end

  # Return the "type[name]" style reference.
  def ref
    "#{resource_type.name.to_s.capitalize}[#{self.title}]"
  end

  def self_refresh?
    resource_type.self_refresh
  end

  # Mark that we're purging.
  def purging
    @purging = true
  end

  # Is this resource being purged?  Used by transactions to forbid
  # deletion when there are dependencies.
  def purging?
    if defined?(@purging)
      @purging
    else
      false
    end
  end

  # Retrieve the title of an object.  If no title was set separately,
  # then use the object's name.
  def title
    unless @title
      if resource_type.validparameter?(name_var)
        @title = self[:name]
      elsif resource_type.validproperty?(name_var)
        @title = self.should(name_var)
      else
        self.devfail "Could not find namevar #{name_var} for #{resource_type.name}"
      end
    end

    @title
  end

  # convert to a string
  def to_s
    self.ref
  end

  # Convert to a transportable object
  def to_trans(ret = true)
    require 'puppet/transportable'
    trans = Puppet::TransObject.new(self.title, resource_type.name)

    values = retrieve_resource
    values.each do |name, value|
      name = name.name if name.respond_to? :name
      trans[name] = value
    end

    @parameters.each do |name, param|
      # Avoid adding each instance name twice
      next if param.class.isnamevar? and param.value == self.title

      # We've already got property values
      next if param.is_a?(Puppet::Property)
      trans[name] = param.value
    end

    trans.tags = self.tags

    # FIXME I'm currently ignoring 'parent' and 'path'

    trans
  end

  def to_resource
    # this 'type instance' versus 'resource' distinction seems artificial
    # I'd like to see it collapsed someday ~JW
    self.to_trans.to_resource
  end

  def virtual?;  !!@virtual;  end
  def exported?; !!@exported; end

  def appliable_to_device?
    resource_type.can_apply_to(:device)
  end

  def appliable_to_host?
    resource_type.can_apply_to(:host)
  end
end
