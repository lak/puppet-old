require 'puppet/parser'

# This module provides all of the methods needed
# to integrate Puppet::Resource::Type and Puppet::Parser::Scope -
# basically, any method that needs to know about Types and Scopes
# at the same time.
module Puppet::Parser::ResourceTypeHarness

  # Now evaluate the code associated with this class or definition.
  def self.evaluate_code(resource_type, resource)

    static_parent = evaluate_parent_type(resource_type, resource)
    scope = static_parent || resource.scope

    scope = scope.newscope(:namespace => resource_type.namespace, :source => self, :resource => resource, :dynamic => !static_parent) unless resource.title == :main
    scope.compiler.add_class(resource_type.name) unless resource_type.definition?

    set_resource_parameters(resource_type, resource, scope)

    resource_type.code.safeevaluate(scope) if resource_type.code

    evaluate_ruby_code(resource, scope) if resource_type.ruby_code
  end

  # Make an instance of the resource type, and place it in the catalog
  # if it isn't in the catalog already.  This is only possible for
  # classes and nodes.  No parameters are be supplied--if this is a
  # parameterized class, then all parameters take on their default
  # values.
  def self.ensure_in_catalog(resource_type, scope, parameters=nil)
    resource_type.definition? and raise ArgumentError, "Cannot create resources for defined resource types without more information"
    type_family = type == :hostclass ? :class : :node

    # Do nothing if the resource already exists; this makes sure we don't
    # get multiple copies of the class resource, which helps provide the
    # singleton nature of classes.
    # we should not do this for classes with parameters
    # if parameters are passed, we should still try to create the resource
    # even if it exists so that we can fail
    # this prevents us from being able to combine param classes with include
    if resource = scope.catalog.resource(type_family, resource_type.name) and !parameters
      return resource
    end
    resource = Puppet::Parser::Resource.new(type_family, resource_type.name, :scope => scope, :source => self)
    if parameters
      parameters.each do |k,v|
        resource.set_parameter(k,v)
      end
    end
    instantiate_resource(resource_type, scope, resource)
    scope.compiler.add_resource(scope, resource)
    resource
  end

  def self.instantiate_resource(resource_type, scope, resource)
    # Make sure our parent class has been evaluated, if we have one.
    if resource_type.parent && !scope.catalog.resource(resource.type, resource_type.parent)
      ensure_in_catalog(parent_type(scope), scope)
    end

    if ['Class', 'Node'].include? resource.type
      scope.catalog.tag(*resource.tags)
    end
  end

  # Set any arguments passed by the resource as variables in the scope.
  def self.set_resource_parameters(resource_type, resource, scope)
    set = {}
    resource.to_hash.each do |param, value|
      param = param.to_sym
      fail Puppet::ParseError, "#{resource.ref} does not accept attribute #{param}" unless resource_type.valid_parameter?(param)

      exceptwrap { scope.setvar(param.to_s, value) }

      set[param] = true
    end

    if @type == :hostclass
      scope.setvar("title", resource.title.to_s.downcase) unless set.include? :title
      scope.setvar("name",  resource.name.to_s.downcase ) unless set.include? :name
    else
      scope.setvar("title", resource.title              ) unless set.include? :title
      scope.setvar("name",  resource.name               ) unless set.include? :name
    end
    scope.setvar("module_name", resource_type.module_name) if resource_type.module_name and ! set.include? :module_name

    if caller_name = scope.parent_module_name and ! set.include?(:caller_module_name)
      scope.setvar("caller_module_name", resource_type.caller_name)
    end
    scope.class_set(resource_type.name, scope) if resource_type.hostclass? or resource_type.node?
    # Verify that all required arguments are either present or
    # have been provided with defaults.
    resource_type.arguments.each do |param, default|
      param = param.to_sym
      next if set.include?(param)

      # Even if 'default' is a false value, it's an AST value, so this works fine
      fail Puppet::ParseError, "Must pass #{param} to #{resource.ref}" unless default

      value = default.safeevaluate(scope)
      scope.setvar(param.to_s, value)

      # Set it in the resource, too, so the value makes it to the client.
      resource[param] = value
    end

  end

  def self.evaluate_parent_type(resource_type, resource)
    return unless klass = resource_type.parent_type(resource.scope) and parent_resource = resource.scope.compiler.catalog.resource(:class, klass.name) || resource.scope.compiler.catalog.resource(:node, klass.name)
    parent_resource.evaluate unless parent_resource.evaluated?
    parent_scope(resource.scope, klass)
  end

  private

  def self.evaluate_ruby_code(resource_type, resource, scope)
    Puppet::DSL::ResourceAPI.new(resource, scope, resource_type, ruby_code).evaluate
  end

  def self.parent_scope(scope, klass)
    scope.class_scope(klass) || raise(Puppet::DevError, "Could not find scope for #{klass.name}")
  end
end
