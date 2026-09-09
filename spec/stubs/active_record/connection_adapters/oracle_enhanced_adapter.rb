# frozen_string_literal: true

# Stub for activerecord-oracle_enhanced-adapter — used by translate_exception_test
# so the patch file can load without the real gem being installed.

module ActiveRecord
  module ConnectionAdapters
    class OracleEnhancedAdapter
    end

    module OracleEnhanced
      class ConnectionException < StandardError; end
    end
  end
end
