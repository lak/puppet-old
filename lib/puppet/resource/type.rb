require 'puppet/parser/parser'
require 'puppet/util/warnings'
require 'puppet/util/errors'
require 'puppet/util/inline_docs'
require 'puppet/parser/ast/leaf'
require 'puppet/dsl'
require 'puppet/util/warnings'
require 'puppet/parameter'
require 'puppet/util/classgen'

class Puppet::Resource::Type
  extend Puppet::Util # for symbolize()
  extend Puppet::Util::ClassGen # for genclass()

  def self.metaparam_module
    @metaparam_module ||= Module.new
  end

  def self.relationship_params
    Puppet::Resource::Type::RelationshipMetaparam.subclasses
  end

  def self.eachmetaparam
    @@metaparams.each { |p| yield p.name }
  end

  # Is the parameter in question a meta-parameter?
  def self.metaparam?(param)
    @@metaparamhash.include?(symbolize(param))
  end

  # Find the metaparameter class associated with a given metaparameter name.
  def self.metaparamclass(name)
    @@metaparamhash[symbolize(name)]
  end

  def self.metaparams
    @@metaparams.collect { |param| param.name }
  end

  def self.metaparamdoc(metaparam)
    @@metaparamhash[metaparam].doc
  end

  # Create a new metaparam.  Requires a block and a name, stores it in the
  # @parameters array, and does some basic checking on it.
  def self.newmetaparam(name, options = {}, &block)
    @@metaparams ||= []
    @@metaparamhash ||= {}
    name = symbolize(name)

    param = genclass(
      name,
      :parent => options[:parent] || Puppet::Parameter,
      :prefix => "MetaParam",
      :hash => @@metaparamhash,
      :array => @@metaparams,
      :attributes => options[:attributes],

      &block
    )

    # Grr.
    param.required_features = options[:required_features] if options[:required_features]

    # Directly pasting code, since doing the method extraction for this is too hard
    # in the current phase.
    if options[:boolean]
      metaparam_module.define_method(name.to_s + "?") do
        val = self[name]
        if val == :true or val == true
          return true
        end
      end
    end

    param.metaparam = true

    param
  end

  Puppet::ResourceType = self
  include Puppet::Util::InlineDocs
  include Puppet::Util::Warnings
  include Puppet::Util::Errors

  RESOURCE_SUPERTYPES = [:hostclass, :node, :definition]

  attr_accessor :file, :line, :doc, :code, :ruby_code, :parent, :resource_type_collection
  attr_reader :type, :namespace, :arguments, :behaves_like, :module_name

  RESOURCE_SUPERTYPES.each do |t|
    define_method("#{t}?") { self.type == t }
  end

  require 'puppet/indirector'
  extend Puppet::Indirector
  indirects :resource_type, :terminus_class => :parser

  def self.from_pson(data)
    name = data.delete('name') or raise ArgumentError, "Resource Type names must be specified"
    type = data.delete('type') || "definition"

    data = data.inject({}) { |result, ary| result[ary[0].intern] = ary[1]; result }

    new(type, name, data)
  end

  def to_pson_data_hash
    data = [:doc, :line, :file, :parent].inject({}) do |hash, param|
      next hash unless (value = self.send(param)) and (value != "")
      hash[param.to_s] = value
      hash
    end

    data['arguments'] = arguments.dup unless arguments.empty?

    data['name'] = name
    data['type'] = type

    data
  end

  def to_pson(*args)
    to_pson_data_hash.to_pson(*args)
  end

  attr_reader :properties
  include Puppet::Util::Warnings

  # All parameters, in the appropriate order.  The key_attributes come first, then
  # the provider, then the properties, and finally the params and metaparams
  # in the order they were specified in the files.
  def allattrs
    key_attributes | (parameters & [:provider]) | properties.collect { |property| property.name } | parameters | self.class.metaparams
  end

  # Retrieve an attribute alias, if there is one.
  def attr_alias(param)
    @attr_aliases[symbolize(param)]
  end

  # Create an alias to an existing attribute.  This will cause the aliased
  # attribute to be valid when setting and retrieving values on the instance.
  def set_attr_alias(hash)
    hash.each do |new, old|
      @attr_aliases[symbolize(new)] = symbolize(old)
    end
  end

  # Find the class associated with any given attribute.
  def attrclass(name)
    @attrclasses ||= {}

    # We cache the value, since this method gets called such a huge number
    # of times (as in, hundreds of thousands in a given run).
    unless @attrclasses.include?(name)
      @attrclasses[name] = case self.attrtype(name)
      when :property; @validproperties[name]
      when :meta; @@metaparamhash[name]
      when :param; @paramhash[name]
      end
    end
    @attrclasses[name]
  end

  # What type of parameter are we dealing with? Cache the results, because
  # this method gets called so many times.
  def attrtype(attr)
    @attrtypes ||= {}
    unless @attrtypes.include?(attr)
      @attrtypes[attr] = case
        when @validproperties.include?(attr); :property
        when @paramhash.include?(attr); :param
        when @@metaparamhash.include?(attr); :meta
        end
    end

    @attrtypes[attr]
  end

  # Create the 'ensure' class.  This is a separate method so other types
  # can easily call it and create their own 'ensure' values.
  def ensurable(&block)
    if block_given?
      self.newproperty(:ensure, :parent => Puppet::Property::Ensure, &block)
    else
      self.newproperty(:ensure, :parent => Puppet::Property::Ensure) do
        self.defaultvalues
      end
    end
  end

  # Should we add the 'ensure' property to this class?
  def ensurable?
    # If the class has all three of these methods defined, then it's
    # ensurable.
    ens = [:exists?, :create, :destroy].inject { |set, method|
      set &&= respond_to?(method)
    }

    ens
  end

  def apply_to_device
    @apply_to = :device
  end

  def apply_to_host
    @apply_to = :host
  end

  def apply_to_all
    @apply_to = :both
  end

  def apply_to
    @apply_to ||= :host
  end

  def can_apply_to(target)
    [ target == :device ? :device : :host, :both ].include?(apply_to)
  end

  # Deal with any options passed into parameters.
  def handle_param_options(param, options)
    options.each do |name, value|
      case name
      when :boolean
        # If it's a boolean parameter, create a method to test the value easily
        instance_module.define_method(param.name.to_s + "?") do
          val = self[param.name]
          if val == :true or val == true
            return true
          end
        end
      when :attributes; nil
      when :parent; nil
      when :required_features; param.required_features = value
      when :namevar; param.isnamevar
      else
        raise "Invalid parameter option #{name}"
      end
    end
  end

  def key_attribute_parameters
    @key_attribute_parameters ||= (
      params = @parameters.find_all { |param|
        param.isnamevar? or param.name == :name
      }
    )
  end

  def key_attributes
    key_attribute_parameters.collect { |p| p.name }
  end

  def title_patterns
    case key_attributes.length
    when 0; []
    when 1;
      identity = lambda {|x| x}
      [ [ /(.*)/m, [ [key_attributes.first, identity ] ] ] ]
    else
      raise Puppet::DevError,"you must specify title patterns when there are two or more key attributes"
    end
  end

  # Create a new parameter.  Requires a block and a name, stores it in the
  # @parameters array, and does some basic checking on it.
  def newparam(name, options = {}, &block)
    options[:attributes] ||= {}

      param = genclass(
        name,
      :parent => options[:parent] || Puppet::Parameter,
      :attributes => options[:attributes],
      :block => block,
      :constant => "Puppet::Type::#{self.name.to_s.capitalize}Parameter#{name.to_s.capitalize}",
      :array => @parameters,
      :hash => @paramhash
    )

    handle_param_options(param, options)

    param
  end

  # Create a new property. The first parameter must be the name of the property;
  # this is how users will refer to the property when creating new instances.
  # The second parameter is a hash of options; the options are:
  # * <tt>:parent</tt>: The parent class for the property.  Defaults to Puppet::Property.
  # * <tt>:retrieve</tt>: The method to call on the provider or @parent object (if
  #   the provider is not set) to retrieve the current value.
  def newproperty(name, options = {}, &block)
    name = symbolize(name)

    # This is here for types that might still have the old method of defining
    # a parent class.
    unless options.is_a? Hash
      raise Puppet::DevError,
        "Options must be a hash, not #{options.inspect}"
    end

    raise Puppet::DevError, "Class #{self.name} already has a property named #{name}" if @validproperties.include?(name)

    if parent = options[:parent]
      options.delete(:parent)
    else
      parent = Puppet::Property
    end

    # We have to create our own, new block here because we want to define
    # an initial :retrieve method, if told to, and then eval the passed
    # block if available.
    prop = genclass(name, :parent => parent, :hash => @validproperties, :attributes => options) do
      # If they've passed a retrieve method, then override the retrieve
      # method on the class.
      if options[:retrieve]
        singleton_class.define_method(:retrieve) do
          provider.send(options[:retrieve])
        end
      end

      class_eval(&block) if block
    end

    # If it's the 'ensure' property, always put it first.
    if name == :ensure
      @properties.unshift prop
    else
      @properties << prop
    end

    prop
  end

  def paramdoc(param)
    @paramhash[param].doc
  end

  # Return the parameter names
  def parameters
    return [] unless defined?(@parameters)
    @parameters.collect { |klass| klass.name }
  end

  # Find the parameter class associated with a given parameter name.
  def paramclass(name)
    @paramhash[name]
  end

  # Return the property class associated with a name
  def propertybyname(name)
    @validproperties[name]
  end

  # Are we a child of the passed class?  Do a recursive search up our
  # parentage tree to figure it out.
  def child_of?(klass)
    return false unless parent

    return(klass == parent_type ? true : parent_type.child_of?(klass))
  end

  # the Type class attribute accessors
  attr_reader :name
  attr_accessor :self_refresh
  include Enumerable, Puppet::Util::ClassGen

  include Puppet::Util
  include Puppet::Util::Logging

  def initialize(type, name, options = {})
    @type = type.to_s.downcase.to_sym
    raise ArgumentError, "Invalid resource supertype '#{type}'" unless RESOURCE_SUPERTYPES.include?(@type)

    name = convert_from_ast(name) if name.is_a?(Puppet::Parser::AST::HostName)

    set_name_and_namespace(name)

    [:code, :doc, :line, :file, :parent].each do |param|
      next unless value = options[param]
      send(param.to_s + "=", value)
    end

    set_arguments(options[:arguments])

    @module_name = options[:module_name]

    ### Old type stuff
    @aliases = Hash.new

    @instance_module = Module.new

    @defaults = {}

    @parameters ||= []

    @validproperties = {}
    @properties = []
    @parameters = []
    @paramhash = {}

    @attr_aliases = {}

    @paramdoc = Hash.new { |hash,key|
      key = key.intern if key.is_a?(String)
      if hash.include?(key)
        hash[key]
      else
        "Param Documentation for #{key} not found"
      end
    }

    @doc ||= ""
  end

  # This is only used for node names, and really only when the node name
  # is a regexp.
  def match(string)
    return string.to_s.downcase == name unless name_is_regex?

    @name =~ string
  end

  # Add code from a new instance to our code.
  def merge(other)
    fail "#{name} is not a class; cannot add code to it" unless type == :hostclass
    fail "#{other.name} is not a class; cannot add code from it" unless other.type == :hostclass
    fail "Cannot have code outside of a class/node/define because 'freeze_main' is enabled" if name == "" and Puppet.settings[:freeze_main]

    if parent and other.parent and parent != other.parent
      fail "Cannot merge classes with different parent classes (#{name} => #{parent} vs. #{other.name} => #{other.parent})"
    end

    # We know they're either equal or only one is set, so keep whichever parent is specified.
    self.parent ||= other.parent

    if other.doc
      self.doc ||= ""
      self.doc += other.doc
    end

    # This might just be an empty, stub class.
    return unless other.code

    unless self.code
      self.code = other.code
      return
    end

    array_class = Puppet::Parser::AST::ASTArray
    self.code = array_class.new(:children => [self.code]) unless self.code.is_a?(array_class)

    if other.code.is_a?(array_class)
      code.children += other.code.children
    else
      code.children << other.code
    end
  end

  def name
    return @name unless @name.is_a?(Regexp)
    @name.source.downcase.gsub(/[^-\w:.]/,'').sub(/^\.+/,'')
  end

  def name_is_regex?
    @name.is_a?(Regexp)
  end

  # MQR TODO:
  #
  # The change(s) introduced by the fix for #4270 are mostly silly & should be 
  # removed, though we didn't realize it at the time.  If it can be established/
  # ensured that nodes never call parent_type and that resource_types are always
  # (as they should be) members of exactly one resource_type_collection the 
  # following method could / should be replaced with:
  #
  # def parent_type
  #   @parent_type ||= parent && (
  #     resource_type_collection.find_or_load([name],parent,type.to_sym) ||
  #     fail Puppet::ParseError, "Could not find parent resource type '#{parent}' of type #{type} in #{resource_type_collection.environment}"
  #   )
  # end
  #
  # ...and then the rest of the changes around passing in scope reverted.
  #
  # XXX This is the only place where we refer to 'scope' in this class...
  def parent_type(scope = nil)
    return nil unless parent

    unless @parent_type
      raise "Must pass scope to parent_type when called first time" unless scope
      unless @parent_type = scope.environment.known_resource_types.send("find_#{type}", [name], parent)
        fail Puppet::ParseError, "Could not find parent resource type '#{parent}' of type #{type} in #{scope.environment}"
      end
    end

    @parent_type
  end

  # Check whether a given argument is valid.
  def valid_parameter?(name)
    name = symbolize(name)
    return true if name == :name
    @valid_parameters ||= {}

    unless @valid_parameters.include?(name)
      @valid_parameters[name] = !!(self.validproperty?(name) or self.validparameter?(name) or self.class.metaparam?(name))
    end

    @valid_parameters[name]
  end
#  def valid_parameter?(param)
#    param = param.to_s
#
#    return true if param == "name"
#    return true if Puppet::Type.metaparam?(param)
#    return false unless defined?(@arguments)
#    return(arguments.include?(param) ? true : false)
#  end

  def set_arguments(arguments)
    @arguments = {}
    return if arguments.nil?

    arguments.each do |arg, default|
      arg = arg.to_s
      warn_if_metaparam(arg, default)
      @arguments[arg] = default
    end
  end

  # does the name reflect a valid property?
  def validproperty?(name)
    name = symbolize(name)
    @validproperties.include?(name) && @validproperties[name]
  end

  # Return the list of validproperties
  def validproperties
    return {} unless defined?(@parameters)

    @validproperties.keys
  end

  # does the name reflect a valid parameter?
  def validparameter?(name)
    raise Puppet::DevError, "Class #{self} has not defined parameters" unless defined?(@parameters)
    !!(@paramhash.include?(name) or @@metaparamhash.include?(name))
  end

  # Is this type's name isomorphic with the object?  That is, if the
  # name conflicts, does it necessarily mean that the objects conflict?
  # Defaults to true.
  def isomorphic?
    if defined?(@isomorphic)
      return @isomorphic
    else
      return true
    end
  end

  # Retrieve all known instances.  Either requires providers or must be overridden.
  def instances
    raise Puppet::DevError, "#{self.name} has no providers and has not overridden 'instances'" if provider_hash.empty?

    # Put the default provider first, then the rest of the suitable providers.
    provider_instances = {}
    providers_by_source.collect do |provider|
      provider.instances.collect do |instance|
        # We always want to use the "first" provider instance we find, unless the resource
        # is already managed and has a different provider set
        if other = provider_instances[instance.name]
          Puppet.warning "%s %s found in both %s and %s; skipping the %s version" %
            [self.name.to_s.capitalize, instance.name, other.resource_type.name, instance.resource_type.name, instance.resource_type.name]
          next
        end
        provider_instances[instance.name] = instance

        new(:name => instance.name, :provider => instance, :audit => :all)
      end
    end.flatten.compact
  end

  # Return a list of one suitable provider per source, with the default provider first.
  def providers_by_source
    # Put the default provider first, then the rest of the suitable providers.
    sources = []
    [defaultprovider, suitableprovider].flatten.uniq.collect do |provider|
      next if sources.include?(provider.source)

      sources << provider.source
      provider
    end.compact
  end

  def new(hash)
    Puppet::OldResource.new(self, hash)
  end

  ###############################
  # All of the provider plumbing for the resource types.
  require 'puppet/provider'
  require 'puppet/util/provider_features'

  # Add the feature handling module.
  include Puppet::Util::ProviderFeatures

  # the Type class attribute accessors
  attr_accessor :providerloader
  attr_writer :defaultprovider

  # Find the default provider.
  def defaultprovider
    unless @defaultprovider
      suitable = suitableprovider

      # Find which providers are a default for this system.
      defaults = suitable.find_all { |provider| provider.default? }

      # If we don't have any default we use suitable providers
      defaults = suitable if defaults.empty?
      max = defaults.collect { |provider| provider.specificity }.max
      defaults = defaults.find_all { |provider| provider.specificity == max }

      retval = nil
      if defaults.length > 1
        Puppet.warning(
          "Found multiple default providers for #{self.name}: #{defaults.collect { |i| i.name.to_s }.join(", ")}; using #{defaults[0].name}"
        )
        retval = defaults.shift
      elsif defaults.length == 1
        retval = defaults.shift
      else
        raise Puppet::DevError, "Could not find a default provider for #{self.name}"
      end

      @defaultprovider = retval
    end

    @defaultprovider
  end

  def provider_hash
    Puppet::Type.provider_hash_by_type(self.name)
  end

  # Retrieve a provider by name.
  def provider(name)
    name = Puppet::Util.symbolize(name)

    # If we don't have it yet, try loading it.
    @providerloader.load(name) unless provider_hash.has_key?(name)
    provider_hash[name]
  end

  # Just list all of the providers.
  def providers
    provider_hash.keys
  end

  def validprovider?(name)
    name = Puppet::Util.symbolize(name)

    (provider_hash.has_key?(name) && provider_hash[name].suitable?)
  end

  # Create a new provider of a type.  This method must be called
  # directly on the type that it's implementing.
  def provide(name, options = {}, &block)
    name = Puppet::Util.symbolize(name)

    if obj = provider_hash[name]
      Puppet.debug "Reloading #{name} #{self.name} provider"
      unprovide(name)
    end

    parent = if pname = options[:parent]
      options.delete(:parent)
      if pname.is_a? Class
        pname
      else
        if provider = self.provider(pname)
          provider
        else
          raise Puppet::DevError,
            "Could not find parent provider #{pname} of #{name}"
        end
      end
    else
      Puppet::Provider
    end

    options[:resource_type] ||= self

    self.providify

    provider = genclass(
      name,
      :parent => parent,
      :hash => provider_hash,
      :prefix => "Provider",
      :constant => "Puppet::Type::#{self.name.to_s.capitalize}::Provider#{name.to_s.capitalize}",
      :block => block,
      :include => feature_module,
      :extend => feature_module,
      :attributes => options
    )

    provider
  end

  # Make sure we have a :provider parameter defined.  Only gets called if there
  # are providers.
  def providify
    return if @paramhash.has_key? :provider

    newparam(:provider) do
      desc "The specific backend for #{self.name.to_s} to use. You will
        seldom need to specify this --- Puppet will usually discover the
        appropriate provider for your platform."

      # This is so we can refer back to the type to get a list of
      # providers for documentation.
      class << self
        attr_accessor :parenttype
      end

      # We need to add documentation for each provider.
      def doc
        @doc + "  Available providers are:\n\n" + parenttype.providers.sort { |a,b|
          a.to_s <=> b.to_s
        }.collect { |i|
          "* **#{i}**: #{parenttype().provider(i).doc}"
        }.join("\n")
      end

      defaultto {
        @resource.resource_type.defaultprovider.name
      }

      validate do |provider_class|
        provider_class = provider_class[0] if provider_class.is_a? Array
        provider_class = provider_class.class.name if provider_class.is_a?(Puppet::Provider)

        unless provider = @resource.resource_type.provider(provider_class)
          raise ArgumentError, "Invalid #{@resource.resource_type.name} provider '#{provider_class}'"
        end
      end

      munge do |provider|
        provider = provider[0] if provider.is_a? Array
        provider = provider.intern if provider.is_a? String
        @resource.provider = provider

        if provider.is_a?(Puppet::Provider)
          provider.class.name
        else
          provider
        end
      end
    end.parenttype = self
  end

  def unprovide(name)
    if provider_hash.has_key? name

      rmclass(
        name,
        :hash => provider_hash,

        :prefix => "Provider"
      )
      if @defaultprovider and @defaultprovider.name == name
        @defaultprovider = nil
      end
    end
  end

  # Return an array of all of the suitable providers.
  def suitableprovider
    providerloader.loadall if provider_hash.empty?
    provider_hash.find_all { |name, provider|
      provider.suitable?
    }.collect { |name, provider|
      provider
    }.reject { |p| p.name == :fake } # For testing
  end

  ###############################
  # All of the relationship code.

  # Specify a block for generating a list of objects to autorequire.  This
  # makes it so that you don't have to manually specify things that you clearly
  # require.
  def autorequire(name, &block)
    @autorequires ||= {}
    @autorequires[name] = block
  end

  # Yield each of those autorequires in turn, yo.
  def eachautorequire
    @autorequires ||= {}
    @autorequires.each { |type, block|
      yield(type, block)
    }
  end

  def to_s
    if defined?(@name)
      "Puppet::Type::#{@name.to_s.capitalize}"
    else
      super
    end
  end

  # Create a block to validate that our object is set up entirely.  This will
  # be run before the object is operated on.
  def validate(&block)
    instance_module.define_method(:validate, &block)
    #@validate = block
  end

  # Convert a simple hash into a Resource instance.
  def hash2resource(hash)
    hash = hash.inject({}) { |result, ary| result[ary[0].to_sym] = ary[1]; result }

    title = hash.delete(:title)
    title ||= hash[:name]
    title ||= hash[key_attributes.first] if key_attributes.length == 1

    raise Puppet::Error, "Title or name must be provided" unless title

    # Now create our resource.
    resource = Puppet::Resource.new(self.name, title)
    [:catalog].each do |attribute|
      if value = hash[attribute]
        hash.delete(attribute)
        resource.send(attribute.to_s + "=", value)
      end
    end

    hash.each do |param, value|
      resource[param] = value
    end
    resource
  end

  def instance_methods(&block)
    @instance_module.class_eval(&block)
  end

  attr_reader :instance_module

  private

  def convert_from_ast(name)
    value = name.value
    if value.is_a?(Puppet::Parser::AST::Regex)
      name = value.value
    else
      name = value
    end
  end

  # Split an fq name into a namespace and name
  def namesplit(fullname)
    ary = fullname.split("::")
    n = ary.pop || ""
    ns = ary.join("::")
    return ns, n
  end

  def set_name_and_namespace(name)
    if name.is_a?(Regexp)
      @name = name
      @namespace = ""
    else
      @name = name.to_s.downcase

      # Note we're doing something somewhat weird here -- we're setting
      # the class's namespace to its fully qualified name.  This means
      # anything inside that class starts looking in that namespace first.
      @namespace, ignored_shortname = @type == :hostclass ? [@name, ''] : namesplit(@name)
    end
  end

  def warn_if_metaparam(param, default)
    return unless Puppet::Type.metaparamclass(param)

    if default
      warnonce "#{param} is a metaparam; this value will inherit to all contained resources"
    else
      raise Puppet::ParseError, "#{param} is a metaparameter; please choose another parameter name in the #{self.name} definition"
    end
  end
end

require 'puppet/provider'
require 'puppet/resource/type/metaparameters'
# Always load these types.
Puppet::Type.type(:component)
