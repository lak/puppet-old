require 'puppet/parser/parser'

module Puppet::Parser::CatalogHelper
    module_function

    # Accept a hash and the current scope and create a resource, adding it
    # to the catalog mid-compile.
    # The hash should include the type and title, along with any other parameters
    # you want to set.  Example hash:
    #   {"type" => "file", "title" => "/tmp/myfile", "content" => "somecontent", "mode" => "755"}
    def create_resource_from_hash(scope, hash)
        resource = hash2resource(scope, hash)
        scope.compiler.add_resource(scope, resource)
    end

    def hash2resource(scope, hash)
        unless type = hash["type"]
            raise ArgumentError, "Must provide type as a hash attribute when creating a resource"
        end

        unless title = hash["title"]
            raise ArgumentError, "Must provide title as a hash attribute when creating a resource"
        end

        resource = Puppet::Parser::Resource.new(:scope => scope, :type => type, :title => title)
        hash.each do |param, value|
            resource.set_parameter(param, value) unless %w{type title}.include?(param)
        end

        resource
    end
end
