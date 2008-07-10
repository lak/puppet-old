require 'puppet/network'

module Puppet::Network::FormatHandler
    def self.extended(klass)
        klass.extend(ClassMethods)

        # LAK:NOTE This won't work in 1.9 ('send' won't be able to send
        # private methods, but I don't know how else to do it.
        klass.send(:include, InstanceMethods)
    end

    module ClassMethods
        def convert_from(format, data)
            raise ArgumentError, "Format %s not supported" % format unless support_format?(format)
            send("from_%s" % format, data)
        end

        def support_format?(name)
            respond_to?("from_%s" % name) and instance_methods.include?("to_%s" % name)
        end
    end

    module InstanceMethods
        def render(format)
            raise ArgumentError, "Format %s not supported" % format unless support_format?(format)
            send("to_%s" % format)
        end

        def support_format?(name)
            self.class.support_format?(name)
        end
    end
end