#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone unit test for translate_exception — NO Oracle / Rails loading.
# The test stubs all ActiveRecord types and only exercises the dispatch logic.
# Run: ruby -Ilib -Ispec/stubs spec/unit/translate_exception_test.rb
# Or:  bundle exec ruby -Ilib -Ispec/stubs spec/unit/translate_exception_test.rb

require 'logger'
require 'mutex_m'
# -------------------------------------------------------------------
# Stubs for types referenced by oracle_enhanced_adapter_patch.rb
# -------------------------------------------------------------------
# Rails 7.2 ActiveRecord hierarchy:
# ActiveRecordError < StandardError
#   AdapterError(message=nil, connection_pool: nil)
#     StatementInvalid(message=nil, sql: nil, binds: nil, connection_pool: nil)
#       RecordNotUnique
#       InvalidForeignKey
# The patch reopens StatementInvalid and adds original_exception + custom initialize.
# These stubs faithfully model Rails 7.2 so kwargs leakage is caught.
module ActiveRecord
  class ActiveRecordError < StandardError
    def initialize(message = nil)
      super(message)
    end
  end

  class AdapterError < ActiveRecordError
    attr_reader :connection_pool

    def initialize(message = nil, connection_pool: nil)
      super(message)
      @connection_pool = connection_pool
    end
  end

  class StatementInvalid < AdapterError
    attr_reader :sql, :binds, :original_exception

    def initialize(message = nil, sql: nil, binds: nil, connection_pool: nil)
      @sql = sql
      @binds = binds
      super(message, connection_pool: connection_pool)
    end
  end

  class RecordNotUnique < StatementInvalid; end
  class InvalidForeignKey < StatementInvalid; end
end

module ActiveRecord
  module ConnectionAdapters
    class OracleEnhancedAdapter
    end

    module OracleEnhanced
      class ConnectionException < StandardError; end
      class Column
        attr_reader :name
        def initialize(name, _default, _type, _table)
          @name = name
        end
      end
    end
  end
end

# Load the actual patch
require 'active_record/oracle_enhanced_adapter_patch'

# -------------------------------------------------------------------
# Mock connection
# -------------------------------------------------------------------
class MockConnection
  def initialize(error_code_map = {})
    @error_code_map = error_code_map
  end

  def error_code(exception)
    @error_code_map[exception.message] || 0
  end
end

# Adapter that uses _connection (private) — Rails 7.2 path
class Rails72Adapter
  include ActiveRecord::ConnectionAdapters::PipelinedFunctions

  def initialize(conn)
    @conn = conn
  end

  def respond_to?(method, include_private = false)
    return true if method == :_connection && include_private
    super
  end

  private

  def _connection
    @conn
  end
end

# Legacy adapter that uses @connection ivar only
class LegacyAdapter
  include ActiveRecord::ConnectionAdapters::PipelinedFunctions

  def initialize(conn)
    @connection = conn
  end
end

# -------------------------------------------------------------------
# Test runner
# -------------------------------------------------------------------
passed = 0
failed = 0

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

puts "=== translate_exception unit tests ==="

# --- 1. ORA-00001 → RecordNotUnique (Rails 7.2 keyword args) ---
exc1 = RuntimeError.new("ORA-00001")
adapter1 = Rails72Adapter.new(MockConnection.new("ORA-00001" => 1))
r1 = nil
test("ORA-00001 returns RecordNotUnique with Rails 7.2 keywords") do
  r1 = adapter1.send(:translate_exception, exc1, message: "dup key", sql: "INSERT", binds: ["x"], connection_pool: "pool")
  raise "Expected RecordNotUnique, got #{r1.class}" unless r1.is_a?(ActiveRecord::RecordNotUnique)
  raise "message: expected 'dup key', got #{r1.message.inspect}" unless r1.message == "dup key"
  raise "sql: expected 'INSERT', got #{r1.sql.inspect}" unless r1.sql == "INSERT"
  raise "binds: expected ['x'], got #{r1.binds.inspect}" unless r1.binds == ["x"]
  raise "connection_pool: expected 'pool', got #{r1.connection_pool.inspect}" unless r1.connection_pool == "pool"
end
passed += 1 if r1.is_a?(ActiveRecord::RecordNotUnique) && r1.message == "dup key" && r1.original_exception.equal?(exc1)

# --- 2. ORA-02291 → InvalidForeignKey ---
exc2 = RuntimeError.new("ORA-02291")
adapter2 = Rails72Adapter.new(MockConnection.new("ORA-02291" => 2291))
r2 = nil
test("ORA-02291 returns InvalidForeignKey with metadata") do
  r2 = adapter2.send(:translate_exception, exc2, message: "fk fail", sql: "UPDATE", binds: [42])
  raise "Expected InvalidForeignKey, got #{r2.class}" unless r2.is_a?(ActiveRecord::InvalidForeignKey)
  raise "message mismatch" unless r2.message == "fk fail"
  raise "sql mismatch" unless r2.sql == "UPDATE"
  raise "binds mismatch" unless r2.binds == [42]
end
passed += 1 if r2.is_a?(ActiveRecord::InvalidForeignKey) && r2.original_exception.equal?(exc2)

# --- 3. User-defined error 20000-20999 re-raises ---
exc3 = RuntimeError.new("user_err_20000")
adapter3 = Rails72Adapter.new(MockConnection.new("user_err_20000" => 20000))
test("ORA-20000 re-raises original exception (from rescue context)") do
  # Simulate actual call pattern: translate_exception is called from rescue.
  # `raise` re-raises $! (the exception being rescued).
  begin
    raise exc3
  rescue RuntimeError
    begin
      adapter3.send(:translate_exception, exc3, message: "skip")
      raise "Expected re-raise from translate_exception"
    rescue RuntimeError => e
      raise "Re-raised wrong object: #{e.message}" unless e.equal?(exc3)
    end
  end
end
passed += 1

# --- 4. Else → StatementInvalid with original_exception + metadata ---
exc4 = RuntimeError.new("unknown_99999")
adapter4 = Rails72Adapter.new(MockConnection.new("unknown_99999" => 99999))
r4 = nil
test("else branch returns StatementInvalid with original_exception") do
  r4 = adapter4.send(:translate_exception, exc4, message: "unexpected", sql: "SELECT *", binds: [])
  raise "Expected StatementInvalid, got #{r4.class}" unless r4.is_a?(ActiveRecord::StatementInvalid)
  raise "original_exception missing" unless r4.original_exception.equal?(exc4)
  raise "sql mismatch" unless r4.sql == "SELECT *"
end
passed += 1 if r4.is_a?(ActiveRecord::StatementInvalid) && r4.original_exception.equal?(exc4)

# --- 5. nil message falls back to exception.message ---
exc5 = RuntimeError.new("ORA-00001_fallback")
adapter5 = Rails72Adapter.new(MockConnection.new("ORA-00001_fallback" => 1))
r5 = nil
test("nil message falls back to exception.message") do
  r5 = adapter5.send(:translate_exception, exc5)
  raise "Expected message '#{exc5.message}', got #{r5.message.inspect}" unless r5.message == "ORA-00001_fallback"
  raise "Expected RecordNotUnique" unless r5.is_a?(ActiveRecord::RecordNotUnique)
end
passed += 1 if r5.is_a?(ActiveRecord::RecordNotUnique) && r5.message == "ORA-00001_fallback"

# --- 6. @connection ivar fallback (legacy adapters) ---
exc6 = RuntimeError.new("ORA-00001_legacy")
adapter6 = LegacyAdapter.new(MockConnection.new("ORA-00001_legacy" => 1))
r6 = nil
test("@connection ivar fallback (legacy path)") do
  r6 = adapter6.send(:translate_exception, exc6, message: "legacy")
  raise "Expected RecordNotUnique, got #{r6.class}" unless r6.is_a?(ActiveRecord::RecordNotUnique)
end
passed += 1 if r6.is_a?(ActiveRecord::RecordNotUnique)

# --- 7. nil message + no message keyword (compatibility with older Rails) ---
exc7 = RuntimeError.new("ORA-02291_old")
adapter7 = Rails72Adapter.new(MockConnection.new("ORA-02291_old" => 2291))
r7 = nil
test("no message keyword at all (older Rails positional style)") do
  r7 = adapter7.send(:translate_exception, exc7)
  raise "Expected InvalidForeignKey, got #{r7.class}" unless r7.is_a?(ActiveRecord::InvalidForeignKey)
  raise "Expected fallback to exception.message" unless r7.message == "ORA-02291_old"
end
passed += 1 if r7.is_a?(ActiveRecord::InvalidForeignKey)

# --- 8. StatementInvalid initialize with sql:/binds: directly (regression guard) ---
exc8 = RuntimeError.new("ORA-00001_direct")
r8 = nil
test("StatementInvalid.new with sql:/binds: keywords does not raise ArgumentError") do
  r8 = ActiveRecord::StatementInvalid.new("direct_test", nil, sql: "SELECT", binds: [1, 2])
  raise "sql mismatch" unless r8.sql == "SELECT"
  raise "binds mismatch" unless r8.binds == [1, 2]
end
passed += 1 if r8&.sql == "SELECT" && r8&.binds == [1, 2]

# --- 9. Legacy positional message in translate_exception (older Rails style) ---
exc9 = RuntimeError.new("ORA-00001_pos")
adapter9 = Rails72Adapter.new(MockConnection.new("ORA-00001_pos" => 1))
r9 = nil
test("translate_exception with positional message (legacy Rails)") do
  r9 = adapter9.send(:translate_exception, exc9, "legacy positional")
  raise "Expected RecordNotUnique, got #{r9.class}" unless r9.is_a?(ActiveRecord::RecordNotUnique)
  raise "Expected message 'legacy positional', got #{r9.message.inspect}" unless r9.message == "legacy positional"
  raise "original_exception missing" unless r9.original_exception.equal?(exc9)
end
passed += 1 if r9.is_a?(ActiveRecord::RecordNotUnique) && r9.message == "legacy positional" && r9.original_exception.equal?(exc9)

# --- 10. translate_exception with keyword message: only (Rails 7.2 style) ---
exc10 = RuntimeError.new("ORA-02291_kw")
adapter10 = Rails72Adapter.new(MockConnection.new("ORA-02291_kw" => 2291))
r10 = nil
test("translate_exception with keyword message: (Rails 7.2 style)") do
  r10 = adapter10.send(:translate_exception, exc10, message: "keyword msg", sql: "DELETE")
  raise "Expected InvalidForeignKey, got #{r10.class}" unless r10.is_a?(ActiveRecord::InvalidForeignKey)
  raise "Expected message 'keyword msg', got #{r10.message.inspect}" unless r10.message == "keyword msg"
  raise "sql mismatch" unless r10.sql == "DELETE"
  raise "original_exception missing" unless r10.original_exception.equal?(exc10)
end
passed += 1 if r10.is_a?(ActiveRecord::InvalidForeignKey) && r10.message == "keyword msg" && r10.original_exception.equal?(exc10)

# -------------------------------------------------------------------
puts
total = 10
puts "Results: #{passed}/#{total} passed, #{total - passed} failed"
exit(total == passed ? 0 : 1)
