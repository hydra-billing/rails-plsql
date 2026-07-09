#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone unit test for Pipelined#reload — NO Oracle / Rails loading.
# Tests the Rails 7.2-compatible reload implementation:
# - clears query cache via connection_pool
# - builds scoped query with pipelined args + primary key
# - copies @association_cache from fresh object and reassigns owners
# - copies @attributes from fresh object
# - resets @new_record and @previously_new_record
# - resets @mutations_from_database and @mutations_before_last_save (Dirty#reload contract)
# - raises RecordNotFound when record is gone
# Run: bundle exec ruby -Ilib -Ispec/stubs spec/unit/pipelined_reload_test.rb

require 'logger'
require 'mutex_m'

# -------------------------------------------------------------------
# Stubs for core Rails/ActiveRecord types
# -------------------------------------------------------------------

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

  # Minimal Base stub: only what Pipelined#reload touches
  class Base
    @clear_query_cache_called = false
    @super_reload_called = false

    class << self
      attr_accessor :clear_query_cache_called
      attr_accessor :super_reload_called

      def connection_pool
        @connection_pool ||= begin
          pool = Object.new
          pool.define_singleton_method(:clear_query_cache) do
            Base.clear_query_cache_called = true
          end
          pool
        end
      end

      def unscoped
        yield
      end

      def primary_key
        "id"
      end

      def where(**args, &block)
        MockRelation.new(**args)
      end
    end
  def reload(options = nil)
    self.class.super_reload_called = true
    self
  end
end


  class MockRelation
    attr_reader :args
    def initialize(**args)
      @args = args
      self.class.last_args = args
    end

    def to_a
      self.class.stubbed_results || []
    end

    class << self
      attr_accessor :stubbed_results
      attr_accessor :last_args
    end
  end
end

# PLSQL module stub (referenced by pipelined_function=)
module PLSQL
  class PipelinedFunction
  end
end

# Arel stub for PipelinedFunctionTableName
module Arel
  module Nodes
    class SqlLiteral < String
    end
  end
end

require 'active_support/core_ext/object/blank'
require 'active_support/concern'
require 'active_support/core_ext/module/delegation'
require 'active_record/plsql/pipelined'

# -------------------------------------------------------------------
# Concrete test model
# -------------------------------------------------------------------
class MockModel < ActiveRecord::Base
  include ActiveRecord::PLSQL::Pipelined

  def self.pipelined?
    true
  end

  def self.pipelined_arguments_names
    %w[num_n_account_id]
  end

  attr_accessor :found_by_arguments
  attr_accessor :id
end

# Helper: create a fresh mock record with given state
def build_fresh(id_value, attrs = { "id" => id_value })
  obj = MockModel.new
  assoc = Object.new
  assoc.define_singleton_method(:owner=) { |o| @owner = o }
  assoc.define_singleton_method(:owner) { @owner }
  obj.instance_variable_set(:@association_cache, { some_assoc: assoc })
  obj.instance_variable_set(:@attributes, attrs)
  obj
end

# -------------------------------------------------------------------
# Test runner (using translate_exception_test.rb pattern)
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

puts "=== Pipelined#reload unit tests ==="

# Reset global state
ActiveRecord::Base.clear_query_cache_called = false

# --- 1. Normal reload with pipelined arguments ---
r1 = nil
test("reload with pipelined arguments finds fresh object and copies state") do
  model = MockModel.new
  model.id = 42
  model.found_by_arguments = []

  fresh = build_fresh(42)
  ActiveRecord::MockRelation.stubbed_results = [fresh]
  ActiveRecord::Base.clear_query_cache_called = false

  r1 = model.reload(num_n_account_id: 123)
  raise "Expected self, got #{r1.class}" unless r1.equal?(model)
  raise "query cache should have been cleared" unless ActiveRecord::Base.clear_query_cache_called
  raise "@new_record should be false" unless model.instance_variable_get(:@new_record) == false
  raise "@previously_new_record should be false" unless model.instance_variable_get(:@previously_new_record) == false
  raise "@attributes not copied" unless model.instance_variable_get(:@attributes) == { "id" => 42 }
  raise "@association_cache empty" if model.instance_variable_get(:@association_cache).empty?
  # Verify owners reassigned
  model.instance_variable_get(:@association_cache).each_value do |assoc|
    raise "owner should be model" unless assoc.owner.equal?(model)
  end
end
results << (r1.is_a?(MockModel) ? true : false)

# --- 2. Reload raises RecordNotFound when fresh object is nil ---
r2 = false
test("reload raises RecordNotFound when record is gone") do
  model = MockModel.new
  model.id = 99
  model.found_by_arguments = []

  ActiveRecord::MockRelation.stubbed_results = []

  begin
    model.reload(num_n_account_id: 456)
    raise "Expected ActiveRecord::RecordNotFound"
  rescue ActiveRecord::RecordNotFound => e
    r2 = e.message.include?("99")
    raise "Message should mention id 99, got: #{e.message}" unless r2
  end
end
results << r2

# --- 3. Query cache is cleared on pipelined reload ---
r3 = false
test("reload clears query cache via connection_pool") do
  model = MockModel.new
  model.id = 1
  model.found_by_arguments = []

  fresh = build_fresh(1)
  ActiveRecord::MockRelation.stubbed_results = [fresh]
  ActiveRecord::Base.clear_query_cache_called = false

  model.reload(num_n_account_id: 789)
  r3 = ActiveRecord::Base.clear_query_cache_called
  raise "query cache should have been cleared" unless r3
end
results << r3

# --- 4. Reload without arguments and without found_by_arguments returns super ---
r4 = false
test("reload without arguments and without found_by_arguments returns super") do
  model = MockModel.new
  model.found_by_arguments = nil
  MockModel.super_reload_called = false

  result = model.reload
  r4 = MockModel.super_reload_called
  raise "Expected self, got #{result.class}" unless result.equal?(model)
  raise "super reload should have been called (guard path)" unless r4
end
results << r4

# --- 5. Reload copies @association_cache and reassigns owners ---
r5 = false
test("reload copies association cache and reassigns owners") do
  model = MockModel.new
  model.id = 7
  model.found_by_arguments = []

  fresh = MockModel.new
  assoc1 = Object.new
  assoc1.define_singleton_method(:owner=) { |o| @owner = o }
  assoc1.define_singleton_method(:owner) { @owner }
  assoc2 = Object.new
  assoc2.define_singleton_method(:owner=) { |o| @owner = o }
  assoc2.define_singleton_method(:owner) { @owner }
  fresh.instance_variable_set(:@association_cache, { a: assoc1, b: assoc2 })
  fresh.instance_variable_set(:@attributes, { "id" => 7 })

  ActiveRecord::MockRelation.stubbed_results = [fresh]
  model.reload(num_n_account_id: 111)

  cache = model.instance_variable_get(:@association_cache)
  r5 = cache.size == 2 && cache[:a].owner.equal?(model) && cache[:b].owner.equal?(model)
  raise "Expected 2 associations, got #{cache.size}" unless cache.size == 2
  raise "Owner of :a should be model" unless cache[:a].owner.equal?(model)
  raise "Owner of :b should be model" unless cache[:b].owner.equal?(model)
end
results << r5

# --- 6. Dirty tracker reset after reload ---
r6 = false
test("reload resets mutation tracker ivars (@mutations_from_database, @mutations_before_last_save)") do
  model = MockModel.new
  model.id = 10
  model.found_by_arguments = []

  # Pre-set mutation trackers as if the record had changes
  model.instance_variable_set(:@mutations_from_database, Object.new)
  model.instance_variable_set(:@mutations_before_last_save, Object.new)

  fresh = build_fresh(10)
  ActiveRecord::MockRelation.stubbed_results = [fresh]

  model.reload(num_n_account_id: 999)

  mfd = model.instance_variable_get(:@mutations_from_database)
  mbls = model.instance_variable_get(:@mutations_before_last_save)
  r6 = mfd.nil? && mbls.nil?
  raise "@mutations_from_database should be nil after reload, got #{mfd.class}" unless mfd.nil?
  raise "@mutations_before_last_save should be nil after reload, got #{mbls.class}" unless mbls.nil?
end
results << r6

# --- 7. Non-empty found_by_arguments converted to query args ---
r7 = false
test("reload with non-empty found_by_arguments passes arg name/value to query") do
  model = MockModel.new
  model.id = 20

  # Argument objects responding to name and value (like Column stubs)
  arg1 = Object.new
  arg1.define_singleton_method(:name) { :n_good_id }
  arg1.define_singleton_method(:value) { 456 }
  model.found_by_arguments = [arg1]

  fresh = build_fresh(20, { "id" => 20, "n_good_id" => 456 })
  ActiveRecord::MockRelation.stubbed_results = [fresh]
  ActiveRecord::MockRelation.last_args = nil

  model.reload(num_n_account_id: 789)

  # Verify the args included both the found_by_arguments and explicit options
  last_args = ActiveRecord::MockRelation.last_args
  r7 = last_args.is_a?(Hash) && last_args[:n_good_id] == 456 && last_args[:num_n_account_id] == 789
  raise "last_args should include n_good_id from found_by_arguments, got: #{last_args.inspect}" unless last_args[:n_good_id] == 456
  raise "last_args should include num_n_account_id from explicit options, got: #{last_args.inspect}" unless last_args[:num_n_account_id] == 789
end
results << r7

# -------------------------------------------------------------------
puts
total = results.size
passed = results.count(true)
puts "Results: #{passed}/#{total} passed, #{total - passed} failed"
exit(total == passed ? 0 : 1)
