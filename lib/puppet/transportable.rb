require 'puppet'
require 'yaml'

module Puppet
  # The transportable objects themselves.  Basically just a hash with some
  # metadata and a few extra methods.  I used to have the object actually
  # be a subclass of Hash, but I could never correctly dump them using
  # YAML.
  class TransObject
    include Enumerable
    attr_accessor :type, :name, :file, :line, :catalog

    attr_writer :tags

    %w{has_key? include? length delete empty? << [] []=}.each { |method|
      define_method(method) do |*args|
        @params.send(method, *args)
      end
    }

    def each
      @params.each { |p,v| yield p, v }
    end

    def initialize(name,type)
      @type = type.to_s.downcase
      @name = name
      @params = {}
      @tags = []
    end

    def longname
      [@type,@name].join('--')
    end

    def ref
      @ref ||= Puppet::Resource.new(@type, @name)
      @ref.to_s
    end

    def tags
      @tags
    end

    # Convert a defined type into a component.
    def to_component
      trans = TransObject.new(ref, :component)
      @params.each { |param,value|
        next unless Puppet::Type::Component.valid_parameter?(param)
        Puppet.debug "Defining #{param} on #{ref}"
        trans[param] = value
      }
      trans.catalog = self.catalog
      Puppet::Type::Component.new(trans)
    end

    def to_hash
      @params.dup
    end

    def to_s
      "#{@type}(#{@name}) => #{super}"
    end

    def to_manifest
      "%s { '%s':\n%s\n}" % [self.type.to_s, self.name,
        @params.collect { |p, v|
          if v.is_a? Array
            "    #{p} => [\'#{v.join("','")}\']"
          else
            "    #{p} => \'#{v}\'"
          end
        }.join(",\n")
        ]
    end

    # Create a normalized resource from our TransObject.
    def to_resource
      result = Puppet::Resource.new(type, name, :parameters => @params.dup)
      result.tag(*tags)

      result
    end

    def to_yaml_properties
      instance_variables.reject { |v| %w{@ref}.include?(v) }
    end

    def to_ref
      ref
    end

    def to_ral
      to_resource.to_ral
    end
  end

  # Just a linear container for objects.  Behaves mostly like an array, except
  # that YAML will correctly dump them even with their instance variables.
  class TransBucket
    include Enumerable

    attr_accessor :name, :type, :file, :line, :classes, :keyword, :top, :catalog

    %w{delete shift include? length empty? << []}.each { |method|
      define_method(method) do |*args|
        #Puppet.warning "Calling #{method} with #{args.inspect}"
        @children.send(method, *args)
        #Puppet.warning @params.inspect
      end
    }

    # Recursively yield everything.
    def delve(&block)
      @children.each do |obj|
        block.call(obj)
        if obj.is_a? self.class
          obj.delve(&block)
        else
          obj
        end
      end
    end

    def each
      @children.each { |c| yield c }
    end

    # Turn our heirarchy into a flat list
    def flatten
      @children.collect do |obj|
        if obj.is_a? Puppet::TransBucket
          obj.flatten
        else
          obj
        end
      end.flatten
    end

    def initialize(children = [])
      @children = children
    end

    def push(*args)
      args.each { |arg|
        case arg
        when Puppet::TransBucket, Puppet::TransObject
          # nada
        else
          raise Puppet::DevError,
            "TransBuckets cannot handle objects of type #{arg.class}"
        end
      }
      @children += args
    end

    # Convert to a parseable manifest
    def to_manifest
      unless self.top
        raise Puppet::DevError, "No keyword; cannot convert to manifest" unless @keyword
      end

      str = "#{@keyword} #{@name} {\n%s\n}"
      str % @children.collect { |child|
        child.to_manifest
      }.collect { |str|
        if self.top
          str
        else
          str.gsub(/^/, "    ") # indent everything once
        end
      }.join("\n\n") # and throw in a blank line
    end

    def to_yaml_properties
      instance_variables
    end

    # Create a resource graph from our structure.
    def to_catalog(clear_on_failure = true)
      catalog = Puppet::Resource::Catalog.new(Facter.value("hostname"))

      # This should really use the 'delve' method, but this
      # whole class is going away relatively soon, hopefully,
      # so it's not worth it.
      delver = proc do |obj|
        obj.catalog = catalog
        unless container = catalog.resource(obj.to_ref)
          container = obj.to_ral
          catalog.add_resource container
        end
        obj.each do |child|
          child.catalog = catalog
          unless resource = catalog.resource(child.to_ref)
            resource = child.to_ral
            catalog.add_resource resource
          end

          catalog.add_edge(container, resource)
          delver.call(child) if child.is_a?(self.class)
        end
      end

      begin
        delver.call(self)
        catalog.finalize
      rescue => detail
        # This is important until we lose the global resource references.
        catalog.clear if (clear_on_failure)
        raise
      end

      catalog
    end

    def to_ref
      unless defined?(@ref)
        if self.type and self.name
          @ref = Puppet::Resource.new(self.type, self.name)
        elsif self.type and ! self.name # This is old-school node types
          @ref = Puppet::Resource.new("node", self.type)
        elsif ! self.type and self.name
          @ref = Puppet::Resource.new("component", self.name)
        else
          @ref = nil
        end
      end
      @ref.to_s if @ref
    end

    def to_ral
      to_resource.to_ral
    end

    # Create a normalized resource from our TransObject.
    def to_resource
      params = defined?(@parameters) ? @parameters.dup : {}
      Puppet::Resource.new(type, name, :parameters => params)
    end

    def param(param,value)
      @parameters ||= {}
      @parameters[param] = value
    end

  end
end

