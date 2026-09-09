#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone unit test for pipelined Arel::Table type casting — NO Oracle / Rails loading.
# Tests the Rails 7.2-compatible typing contract:
# - pipelined arel_table includes klass: / type_caster:
# - bound_table_for_pipelined includes klass: / type_caster:
# - type_for_attribute on the resulting table does NOT raise NoMethodError
# Run: bundle exec ruby -Ilib -Ispec/stubs spec/unit/pipelined_arel_type_test.rb

# -------------------------------------------------------------------
# Minimal stubs for Arel, ActiveRecord, PLSQL types
# -------------------------------------------------------------------

module Arel
  class Table
    attr_reader :name, :klass, :type_caster

    def initialize(name, as: nil, klass: nil, type_caster: klass&.type_caster)
      @name = name
      @as = as
      @klass = klass
      @type_caster = type_caster
    end

    def type_for_attribute(name)
      type_caster.type_for_attribute(name) if type_caster
    end
  end

  module Nodes
    class SqlLiteral < String
    end

    class BoundSqlLiteral < SqlLiteral
      attr_reader :bind_params, :named_binds
      def initialize(value, bind_params = nil, named_binds = {})
        super(value)
        @bind_params = bind_params
        @named_binds = named_binds
      end
    end
  end
end

module ActiveRecord
  class ActiveRecordError < StandardError; end
  class RecordNotFound < StandardError; end

  module ConnectionAdapters
    module OracleEnhanced
      class Column
        attr_reader :name
        def initialize(name, _default, _type, _table)
          @name = name
        end
      end
    end
  end

  class Type
    def self.default_value
      nil
    end
  end

  class Base
    class << self
      def type_caster
        @type_caster ||= begin
          tc = Object.new
          tc.define_singleton_method(:type_for_attribute) do |name|
            ActiveRecord::Type.default_value
          end
          tc
        end
      end
    end
  end

  # Stub for Relation (PipelinedRelation inherits from this)
  class Relation
    class FromClause
      def initialize(value, name)
        @value = value
        @name = name
      end
    end

    def initialize(klass = nil)
      @klass = klass
    end
  end
end

module PLSQL
  class PipelinedFunction
  end
end

# -------------------------------------------------------------------
# Load the actual pipelined module
# -------------------------------------------------------------------
require 'active_support/core_ext/object/blank'
require 'active_support/concern'
require 'active_support/core_ext/module/delegation'
require 'active_record/plsql/pipelined'
require 'active_record/plsql/pipelined_relation'

# -------------------------------------------------------------------
# Test model class
# -------------------------------------------------------------------
class MockPipelinedModel < ActiveRecord::Base
  include ActiveRecord::PLSQL::Pipelined

  def self.pipelined?
    true
  end

  def self.pipelined_arguments_names
    %w[p_name]
  end

  def self.pipelined_function_alias
    'FNU'
  end

  def self.table_name_with_arguments
    'TABLE(find_users_by_name(:p_name))'
  end

  def self.pipelined_function
    true
  end
end

# -------------------------------------------------------------------
# Test runner (same pattern as pipelined_reload_test.rb)
# -------------------------------------------------------------------
results = []

def test(description)
  print "  #{description}... "
  begin
    yield
    puts "PASS"
    true
  rescue => e
    puts "FAIL (#{e.class}: #{e.message})"
    puts "        #{e.backtrace.first(3).join("\n        ")}" if ENV['VERBOSE']
    false
  end
end

puts "=== Pipelined Arel::Table type casting unit tests ==="

# --- 1. arel_table has klass set to the model class ---
r1 = false
test("arel_table passes klass: self to Arel::Table") do
  table = MockPipelinedModel.arel_table
  r1 = table.klass.equal?(MockPipelinedModel)
  raise "Expected klass to be MockPipelinedModel, got #{table.klass}" unless r1
end
results << r1

# --- 2. arel_table has type_caster set ---
r2 = false
test("arel_table has non-nil type_caster") do
  table = MockPipelinedModel.arel_table
  r2 = !table.type_caster.nil?
  raise "Expected type_caster to be non-nil" unless r2
end
results << r2

# --- 3. type_for_attribute on arel_table does not raise ---
r3 = false
test("arel_table.type_for_attribute('id') does not raise NoMethodError") do
  table = MockPipelinedModel.arel_table
  result = table.type_for_attribute('id')
  r3 = true
  # result may be nil (Type.default_value) — that's acceptable
end
results << r3

# --- 4. bound_table_for_pipelined passes klass: klass ---
r4 = false
test("bound_table_for_pipelined passes klass: klass to Arel::Table") do
  binds = [Object.new] # just a placeholder, value not used
  table = ActiveRecord::PLSQL::PipelinedRelation.bound_table_for_pipelined(MockPipelinedModel, binds)
  r4 = table.klass.equal?(MockPipelinedModel)
  raise "Expected klass to be MockPipelinedModel, got #{table.klass}" unless r4
end
results << r4

# --- 5. bound_table_for_pipelined has type_caster set ---
r5 = false
test("bound_table_for_pipelined has non-nil type_caster") do
  binds = [Object.new]
  table = ActiveRecord::PLSQL::PipelinedRelation.bound_table_for_pipelined(MockPipelinedModel, binds)
  r5 = !table.type_caster.nil?
  raise "Expected type_caster to be non-nil" unless r5
end
results << r5

# --- 6. bound_table_for_pipelined type_for_attribute does not raise ---
r6 = false
test("bound_table_for_pipelined type_for_attribute('id') does not raise") do
  binds = [Object.new]
  table = ActiveRecord::PLSQL::PipelinedRelation.bound_table_for_pipelined(MockPipelinedModel, binds)
  result = table.type_for_attribute('id')
  r6 = true
end
results << r6

# -------------------------------------------------------------------
puts
total = results.size
passed = results.count(true)
puts "Results: #{passed}/#{total} passed, #{total - passed} failed"
exit(total == passed ? 0 : 1)
