#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone unit test for Pipelined relation freshness — NO Oracle / Rails loading.
# Tests that Pipelined::ClassMethods#relation returns a fresh instance each call,
# preventing mutable from_clause / bind state from leaking between owners/scopes.
# Run: bundle exec ruby -Ilib -Ispec/stubs spec/unit/pipelined_relation_leak_test.rb

require 'logger'
require 'mutex_m'
require 'active_support/core_ext/hash/keys'

# -------------------------------------------------------------------
# Minimal stubs for Arel types
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

# -------------------------------------------------------------------
# Minimal stubs for ActiveRecord types
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

  class Type
    def self.default_value
      nil
    end
  end


  class Base
    class << self
      def connection_pool
        @connection_pool ||= begin
          pool = Object.new
          pool.define_singleton_method(:clear_query_cache) {}
          pool
        end
      end

      def type_caster
        @type_caster ||= begin
          tc = Object.new
          tc.define_singleton_method(:type_for_attribute) { |_name| Type.default_value }
          tc
        end
      end
    end
  end

  # Minimal Relation stub: only what PipelinedRelation needs to inherit
  class Relation
    class FromClause
      attr_reader :value, :name
      def initialize(value, name)
        @value = value
        @name = name
      end
    end

    attr_reader :klass, :from_clause, :loaded, :table, :predicate_builder
    attr_writer :from_clause, :loaded

    def initialize(klass = nil, table: nil, predicate_builder: nil)
      @klass = klass
      @table = table
      @predicate_builder = predicate_builder
      @from_clause = FromClause.new(nil, nil)
      @loaded = false
    end

    def spawn
      relation = clone
      relation.loaded = false
      relation
    end

    def where!(opts = nil, *rest)
      self
    end
  end

  module Querying
    def where(*args)
      spawn.where!(*args)
    end

    def spawn
      relation.spawn
    end

    def relation
      raise 'relation must be overridden by ClassMethods#relation'
    end
  end

  module Core
    def relation
      @relation ||= Relation.new(self)
    end
  end
end

module ActiveModel
  class Attribute
    def self.with_cast_value(name, value, type)
      value
    end
  end
end

# Include Querying and Core into Base for the mock model
ActiveRecord::Base.extend(ActiveRecord::Querying)
ActiveRecord::Base.extend(ActiveRecord::Core)

# -------------------------------------------------------------------
# PLSQL module stub
# -------------------------------------------------------------------
module PLSQL
  class PipelinedFunction
    def arguments
      { 0 => { 'num_n_account_id' => { position: 1, data_type: 'NUMBER' } } }
    end

    def package
      nil
    end

    def procedure
      'get_servs'
    end
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
# Test model classes
# -------------------------------------------------------------------
class MockPipelinedModel < ActiveRecord::Base
  include ActiveRecord::PLSQL::Pipelined

  def self.pipelined?
    true
  end

  def self.pipelined_arguments_names
    %w[num_n_account_id]
  end

  def self.pipelined_function_alias
    'FNU'
  end

  def self.table_name_with_arguments
    'TABLE(get_servs(:num_n_account_id))'
  end

  def self.pipelined_function
    @pipelined_function ||= PLSQL::PipelinedFunction.new
  end

  # Must set @pipelined_function ivar so pipelined_function_name (which reads
  # the ivar directly, not via self.pipelined_function) can access .package/.procedure.
  @pipelined_function = PLSQL::PipelinedFunction.new

  def self.arel_table
    @arel_table ||= Arel::Table.new(
      table_name_with_arguments,
      as: pipelined_function_alias,
      klass: self
    )
  end

  def self.predicate_builder
    @predicate_builder ||= Object.new
  end

  # Bypass get_pipelined_arguments (needs real Oracle metadata) and return
  # clean stubs so pipelined_arguments.any? works in the guard.
  def self.pipelined_arguments
    @pipelined_arguments ||= [
      ActiveRecord::ConnectionAdapters::OracleEnhanced::Column.new('num_n_account_id', nil, 'NUMBER', table_name_with_arguments)
    ]
  end
end

# A second model class to verify class-level isolation
class AnotherPipelinedModel < ActiveRecord::Base
  include ActiveRecord::PLSQL::Pipelined

  def self.pipelined?
    true
  end

  def self.pipelined_arguments_names
    %w[user_id]
  end

  def self.pipelined_function_alias
    'SNU'
  end

  def self.table_name_with_arguments
    'TABLE(get_subscriptions(:user_id))'
  end

  def self.pipelined_function
    @pipelined_function ||= PLSQL::PipelinedFunction.new
  end

  @pipelined_function = PLSQL::PipelinedFunction.new

  def self.arel_table
    @arel_table ||= Arel::Table.new(
      table_name_with_arguments,
      as: pipelined_function_alias,
      klass: self
    )
  end

  def self.predicate_builder
    @predicate_builder ||= Object.new
  end

  def self.pipelined_arguments
    @pipelined_arguments ||= [
      ActiveRecord::ConnectionAdapters::OracleEnhanced::Column.new('user_id', nil, 'NUMBER', table_name_with_arguments)
    ]
  end
end

# -------------------------------------------------------------------
# Test runner (same pattern as existing unit tests)
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

puts "=== PipelinedRelation fresh instance / state leak unit tests ==="
puts

# Note: relation() is private in Pipelined::ClassMethods, so we use .send(:relation).
# The core contract is: each call creates a fresh PipelinedRelation, not a memoized one.

# --- 1. relation returns fresh instance each call (no memoization) ---
r1 = false
test("relation returns a new instance each call, not memoized") do
  rel1 = MockPipelinedModel.send(:relation)
  rel2 = MockPipelinedModel.send(:relation)
  r1 = !rel1.equal?(rel2)
  raise "Expected different relation objects, got same #{rel1.object_id}" unless r1
end
results << r1

# --- 2. relation instances have independent from_clause ---
r2 = false
test("relation instances have independent from_clause objects") do
  rel1 = MockPipelinedModel.send(:relation)
  rel2 = MockPipelinedModel.send(:relation)

  # Mutate rel1's from_clause via from!
  rel1.from!('TABLE(get_servs(:a1))', 'FNU', [:bound_value_1])
  r2 = rel1.from_clause.object_id != rel2.from_clause.object_id
  raise "Expected from_clause objects to differ" unless r2
  # rel2 should still have clean from_clause (no binds, nil value)
  raise "rel2 from_clause value should be nil, got #{rel2.from_clause.value.inspect}" if rel2.from_clause.value
end
results << r2

# --- 3. Class-level isolation: different models have independent relation state ---
r3 = false
test("different pipelined models have independent relation state") do
  mock_rel = MockPipelinedModel.send(:relation)
  another_rel = AnotherPipelinedModel.send(:relation)

  r3 = !mock_rel.equal?(another_rel)
  raise "Expected different relation objects for different models" unless r3
  raise "MockPipelinedModel relation klass mismatch" unless mock_rel.klass == MockPipelinedModel
  raise "AnotherPipelinedModel relation klass mismatch" unless another_rel.klass == AnotherPipelinedModel
end
results << r3

# --- 4. Each call to relation returns fresh object even after prior where calls ---
r4 = false
test("relation returns fresh object even after prior calls") do
  # Call where (uses spawn → relation internally) to simulate prior query
  _q = MockPipelinedModel.send(:relation).where(num_n_account_id: 100)
  # Fresh relation should not carry any state from the where call
  fresh_rel = MockPipelinedModel.send(:relation)
  r4 = fresh_rel.from_clause.value.nil?
  raise "fresh relation from_clause value should be nil, got #{fresh_rel.from_clause.value.inspect}" unless r4
end
results << r4

# --- 5. Sequential where calls with different args produce independent bind values ---
r5 = false
test("sequential where calls with different args keep distinct bind values") do
  # Simulate two sequential queries from the same model with different owners
  q1 = MockPipelinedModel.send(:relation).where(num_n_account_id: 1003)
  q2 = MockPipelinedModel.send(:relation).where(num_n_account_id: 5433)

  raise "q1 should be a relation" unless q1.is_a?(ActiveRecord::Relation)
  raise "q2 should be a relation" unless q2.is_a?(ActiveRecord::Relation)
  # Both must have table_binds from the pipelined from_clause
  q1_binds = q1.from_clause.table_binds
  q2_binds = q2.from_clause.table_binds
  raise "q1 should have binds, got empty" if q1_binds.empty?
  raise "q2 should have binds, got empty" if q2_binds.empty?
  # Same table value is fine (same function), but binds MUST be independent
  raise "table_binds should not be the same object" if q1_binds.equal?(q2_binds)
  raise "Expected first bind value 1003, got #{q1_binds.first.inspect}" unless q1_binds.first == 1003
  raise "Expected first bind value 5433, got #{q2_binds.first.inspect}" unless q2_binds.first == 5433
  r5 = true
end
results << r5

# -------------------------------------------------------------------
puts
total = results.size
passed = results.count(true)
puts "Results: #{passed}/#{total} passed, #{total - passed} failed"
exit(total == passed ? 0 : 1)
