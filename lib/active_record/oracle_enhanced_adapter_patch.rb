require 'active_record/connection_adapters/oracle_enhanced_adapter'
require 'plsql/pipelined_function'

# ActiveRecord already carries #sql, #binds and #connection_pool; the only thing
# missing is the driver exception that produced the error. Delegate everything
# else to the framework rather than re-implementing its initializer, so the
# `message || $!&.message` fallback and the connection_pool wiring keep working.
class ActiveRecord::StatementInvalid
  attr_reader :original_exception

  def initialize(message = nil, original_exception = nil, **kwargs)
    super(message, **kwargs)
    @original_exception = original_exception
  end
end

module ActiveRecord
  module ConnectionAdapters
    # interface independent methods
    module PipelinedFunctions
      def columns(table, name = nil)
        begin
          return super(table)
        rescue OracleEnhanced::ConnectionException => error
          # Will try to find a pipelined function
        end

        function_name, package_name = parse_function_name(table)

        if package_name
          function = plsql.send(package_name.downcase.to_sym)[function_name.downcase]
        else
          raise error.class, error.message
        end

        if function
          arguments_metadata = function.arguments[0].sort_by {|arg| arg[1][:position]}
          arguments = arguments_metadata.map do |arg_name, argument|
            OracleEnhanced::Column.new(arg_name.to_s, nil, fetch_type_metadata(argument[:data_type]), table)
          end

          element = function.return && function.return[:element]
          unless element && element[:fields]
            raise "Pipelined function '#{function_name}' return type metadata is incomplete: " \
                  ":element is nil or missing :fields. This may be caused by Oracle 18c+ " \
                  "composite type metadata changes. Ensure ruby-plsql is up to date, " \
                  "or check that ALL_PLSQL_COLL_TYPES / ALL_PLSQL_TYPE_ATTRS contain " \
                  "the type definition for #{function.return && function.return[:type_name]}."
          end

          return_columns = element[:fields].sort_by {|col_name, col| col[:position]}.map do |col_name, metadata|
            metadata.merge(name: col_name)
          end

          return_columns.map do |col|
            OracleEnhanced::Column.new(col[:name].to_s, nil, fetch_type_metadata(col[:data_type]), table)
          end + arguments
        else
          raise error.class, error.message
        end
      end

      def parse_function_name(name)
        name = name.to_s.upcase
        # We can get name of function with calling syntax
        # Just extract function name
        if name =~ /\ATABLE\((([^.]+\.)[^.]+)\([^)]+\)\)\z/
          name = $1
        end
        name.split('.').reverse
      end

      protected

      def translate_exception(exception, message = nil, sql: nil, binds: nil, connection_pool: nil, **kwargs)
        # oracle_enhanced exposes the OCI connection (which carries #error_code) as the
        # private `_connection`; older adapters kept it in the @connection ivar.
        # respond_to? needs the `true` flag to see a private method.
        conn = respond_to?(:_connection, true) ? _connection : @connection

        # Rails 7.2 calls this with `message:` as a keyword; older versions passed it
        # positionally.
        message ||= kwargs.delete(:message) || exception.message
        # Rails 7.2 does not pass connection_pool to translate_exception - it hands the
        # adapter's own pool to the error - so fall back to that rather than leaving nil.
        connection_pool ||= @pool

        case conn.error_code(exception)
        when 1
          RecordNotUnique.new(message, exception, sql: sql, binds: binds, connection_pool: connection_pool)
        when 2291
          InvalidForeignKey.new(message, exception, sql: sql, binds: binds, connection_pool: connection_pool)
        when 20000..20999 # Skip user-defined errors
          raise
        else
          StatementInvalid.new(message, exception, sql: sql, binds: binds, connection_pool: connection_pool)
        end
      end

      def type_cast(value, *)
        if value.is_a?(BigDecimal)
          value
        else
          super
        end
      end
    end

    OracleEnhancedAdapter.prepend(PipelinedFunctions)
  end
end
