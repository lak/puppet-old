#!/usr/bin/env ruby

require File.dirname(__FILE__) + '/../../spec_helper'

require 'puppet/parser/catalog_helper'

describe Puppet::Parser::CatalogHelper do
    before do
        @helper = Puppet::Parser::CatalogHelper
        @scope = stub 'scope', :source => mock("source")
    end

    it "should be able to convert a hash to resource" do
        @helper.should respond_to(:hash2resource)
    end

    describe "when converting hashes to resources" do
        it "should return a Parser resource when provided a hash" do
            @helper.hash2resource(@scope, "type" => "file", "title" => "/foo").should be_instance_of(Puppet::Parser::Resource)
        end

        it "should fail if no scope was provided" do
            lambda { @helper.hash2resource("title" => "/foo") }.should raise_error(ArgumentError)
        end

        it "should fail if no type was provided" do
            lambda { @helper.hash2resource(@scope, "title" => "/foo") }.should raise_error(ArgumentError)
        end

        it "should fail if no title was provided" do
            lambda { @helper.hash2resource(@scope, "type" => "file") }.should raise_error(ArgumentError)
        end

        it "should set the type of the resource to the provided type" do
            @helper.hash2resource(@scope, "type" => "file", "title" => "/foo").type.to_s.downcase.should == "file"
        end

        it "should set the title of the resource to the provided title" do
            @helper.hash2resource(@scope, "type" => "file", "title" => "/foo").title.should == "/foo"
        end

        it "should set all provided parameters appropriately" do
            resource = @helper.hash2resource(@scope, "type" => "file", "title" => "/foo", "owner" => "root", "mode" => "0775")
            resource["owner"].should == "root"
            resource["mode"].should == "0775"
        end

        it "should be able to handle arrays as parameter values" do
            resource = @helper.hash2resource(@scope, "type" => "file", "title" => "/foo", "owner" => ["root", "admin"])
            resource["owner"].should == ["root", "admin"]
        end
    end

    it "should be able to add resources to the compiler" do
        @helper.should respond_to(:create_resource_from_hash)
    end

    describe "when adding resources to the compiler" do
        before do
            @hash = {"type" => "file", "title" => "/foo"}
            @resource = mock("resource")
            @scope.stubs(:compiler).returns mock("compiler")
            @scope.compiler.stubs(:add_resource)
        end

        it "should convert the hash into a resource" do
            @helper.expects(:hash2resource).with(@scope, @hash).returns @resource
            @helper.create_resource_from_hash(@scope, @hash)
        end

        it "should add the resource" do
            @scope.compiler.expects(:add_resource).with { |scope, res| scope == scope and res.is_a?(Puppet::Parser::Resource) }
            @helper.create_resource_from_hash(@scope, @hash)
        end

        it "should return nil" do
            @helper.create_resource_from_hash(@scope, @hash).should be_nil
        end
    end
end
