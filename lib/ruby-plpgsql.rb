class PLPGSQL
  class ArgumentHandler
    def call(_routine, arg)
      arg
    end
  end

  attr_writer :activerecord_class

  attr_accessor :argument_handler

  def initialize(activerecord_class = nil)
    @activerecord_class = activerecord_class
    @cache = {}
    @argument_handler = ArgumentHandler.new
  end

  class Schema
    attr_reader :schema_name

    alias name schema_name

    def initialize(ar_class:, schema_name:, argument_handler:)
      @ar_class = ar_class
      @schema_name =
        case schema_name
        in String
          schema_name
        in Symbol
          schema_name.to_s
        else
          raise ArgumentError, "Invalid schema name: #{schema_name}"
        end
      @cache = {}
      @name_cache = {}
      @argument_handler = argument_handler
    end

    def [](function_name)
      @cache[normalize_function_name(function_name)] ||= resolve_routine(function_name)
    end

    private

    def normalize_function_name(name)
      @name_cache[name] ||= name.to_s.downcase
    end

    def resolve_routine(name)
      routine_info = @ar_class.connection.select_one(<<-SQL)
        SELECT routine_type, specific_name
        FROM information_schema.routines
        WHERE routine_schema = '#{@schema_name.to_s.downcase}'
        AND routine_name = '#{normalize_function_name(name)}'
      SQL

      if routine_info
        case routine_info['routine_type']
        when 'PROCEDURE'
          Procedure.new(
            ar_class: @ar_class,
            schema_name: @schema_name,
            routine_name: name,
            specific_name: routine_info['specific_name'],
            argument_handler: @argument_handler
          )
        when 'FUNCTION'
          Function.new(
            ar_class: @ar_class,
            schema_name: @schema_name,
            routine_name: name,
            specific_name: routine_info['specific_name'],
            argument_handler: @argument_handler
          )
        else
          raise "Unknown routine type: #{routine_info['routine_type']}"
        end
      else
        MissingRoutine.new(
          ar_class: @ar_class,
          schema_name: @schema_name,
          routine_name: name,
          specific_name: nil,
          argument_handler: @argument_handler
        )
      end
    end

    def method_missing(name, *args, **kwargs, &block)
      self[name].(*args, **kwargs, &block)
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end

  class Routine
    def self.find(plpgsql, schema_name:, routine_name:)
      plpgsql.public_send(schema_name)[routine_name]
    end

    def initialize(ar_class:, schema_name:, routine_name:, specific_name:, argument_handler:)
      @ar_class = ar_class
      @schema_name = schema_name
      @routine_name = routine_name
      @specific_name = specific_name
      @argument_handler = argument_handler
    end

    def schema_name
      @schema_name
    end

    alias schema schema_name

    def routine_name
      @routine_name
    end

    alias function_name routine_name
    alias name routine_name

    def overloaded?
      false
    end

    def arguments
      @arguments ||= get_argument_metadata
    end

    def argument_list
      @argument_list ||= begin
        args = arguments[0] || {}
        args.keys.sort { |k1, k2| args[k1][:position] <=> args[k2][:position] }
      end
    end

    def out_list
      @out_list ||= begin
        args = arguments[0] || {}
        argument_list.select { |k| args[k][:in_out] =~ /OUT/ }
      end
    end

    private

    def get_argument_metadata
      # Build hash similar to Oracle's structure, but without overloading
      args = {}

      @ar_class.connection.select_all(<<-SQL).each do |row|
          SELECT
            parameter_name,
            data_type,
            parameter_mode,
            ordinal_position,
            parameter_default,
            character_maximum_length,
            numeric_precision,
            numeric_scale
          FROM information_schema.parameters
          WHERE specific_schema = '#{@schema_name.to_s.downcase}'
          AND specific_name = '#{@specific_name}'
          AND parameter_name IS NOT NULL
          ORDER BY ordinal_position
        SQL

        param_name = row['parameter_name']&.downcase&.to_sym
        next unless param_name

        args[param_name] = {
          position: row['ordinal_position'].to_i,
          data_type: row['data_type'],
          in_out: case row['parameter_mode']
                  when 'IN' then 'IN'
                  when 'OUT' then 'OUT'
                  when 'INOUT' then 'IN OUT'
                  else 'IN'
                  end,
          data_length: row['character_maximum_length']&.to_i,
          data_precision: row['numeric_precision']&.to_i,
          data_scale: row['numeric_scale']&.to_i,
          defaulted: row['parameter_default'] ? 'Y' : 'N'
        }
      end

      # Return hash with overload key 0 to match Oracle structure
      { 0 => args }
    end

    def args_to_string(args)
      [
        *args.flat_map { |arg|
          if arg.is_a?(::Hash)
            arg.map do |key, value|
              arg_name = @argument_handler.call(self, key)
              "#{arg_name} => #{value_to_string(value)}"
            end
          else
            [value_to_string(arg)]
          end
        },
        *out_args
      ].join(', ')
    end

    def out_args
      @out_args ||= begin
        args = arguments[0] || {}
        argument_list.select { |k| args[k][:in_out] =~ /OUT/ }.map { |k|
          arg_name = @argument_handler.call(self, k)
          "#{arg_name} => NULL"
        }
      end
    end

    def value_to_string(value)
      if value.is_a?(::String)
        if value.empty?
          "NULL"
        else
          "'#{value}'"
        end
      elsif value.is_a?(::Array)
        "'{#{value.join(', ')}}'"
      elsif value.nil?
        'null'
      elsif value.is_a?(::Time) || value.is_a?(::DateTime)
        "'#{value.strftime('%Y-%m-%d %H:%M:%S')}'::timestamp(0)"
      else
        value.to_s
      end
    end
  end

  class Function < Routine
    def call(*args, &_block)
      if set_of?
        @ar_class.connection.select_all(
          "select #{@schema_name}.#{name}(#{args_to_string(args)})"
        ).to_a
      else
        @ar_class.connection.select_value(
          "select #{@schema_name}.#{name}(#{args_to_string(args)})"
        )
      end
    end

    def set_of?
      if defined?(@set_of)
        @set_of
      else
        # determine if the function returns a set of rows
        # by checking the return type
        @set_of = @ar_class.connection.select_value(
          "SELECT pg_get_function_result(oid) FROM pg_proc WHERE proname = '#{@routine_name}'"
        ) =~ /setof/i
      end
    end

    def columns
      if set_of?
        # get return type of the function
        return_type = @ar_class.connection.select_value(<<-SQL).downcase
          SELECT pg_get_function_result(oid) FROM pg_proc WHERE proname = '#{@routine_name}'
        SQL

        # Check if it's SETOF RECORD or SETOF specific_type
        if return_type =~ /^setof record$/i
          # For SETOF RECORD, get columns from function parameters (OUT params or RETURNS TABLE)
          result = @ar_class.connection.select_all(<<-SQL)
            SELECT
              parameter_name,
              data_type,
              ordinal_position,
              parameter_mode
            FROM information_schema.parameters
            WHERE specific_schema = '#{@schema_name.to_s.downcase}'
            AND specific_name = '#{@specific_name}'
            AND parameter_mode IN ('OUT', 'INOUT', 'TABLE')
            ORDER BY ordinal_position
          SQL

          result.map do |row|
            name = row['parameter_name']
            type = row['data_type']

            # Create a simple column-like object with name and type
            OpenStruct.new(
              name: name,
              type: type,
              sql_type: type
            )
          end
        else
          # For SETOF specific_type, extract the type name and query its attributes
          type_match = return_type.match(/^setof ([\w\.]+)/)
          if type_match
            type_name = type_match[1]

            # Check if type includes schema
            if type_name.include?('.')
              schema, table = type_name.split('.', 2)
            else
              # Use the function's schema as default
              schema = @schema_name.to_s.downcase
              table = type_name
            end

            # Query composite type attributes from pg_type and pg_attribute
            # This works for both custom composite types and table types
            result = @ar_class.connection.select_all(<<-SQL)
              SELECT
                a.attname AS name,
                format_type(a.atttypid, a.atttypmod) AS sql_type,
                pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
                a.attnum AS position
              FROM pg_type t
              JOIN pg_namespace n ON t.typnamespace = n.oid
              JOIN pg_attribute a ON a.attrelid = t.typrelid
              WHERE n.nspname = '#{schema}'
              AND t.typname = '#{table}'
              AND a.attnum > 0
              AND NOT a.attisdropped
              ORDER BY a.attnum
            SQL

            result.map do |row|
              OpenStruct.new(
                name: row['name'],
                type: row['data_type'],
                sql_type: row['sql_type']
              )
            end
          else
            []
          end
        end
      else
        nil
      end
    end
  end

  class Procedure < Routine
    def call(*args, &_block)
      @ar_class.connection.execute(
        "call #{@schema_name}.#{name}(#{args_to_string(args)})"
      ).to_a.first
    end
  end

  class MissingRoutine < Routine
    def call(*args, &_block)
      raise "Missing routine: #{@schema_name}.#{@routine_name}"
    end
  end

  private

  def respond_to_missing?(_name, _include_private = false)
    true
  end

  def method_missing(schema_name)
    @cache[schema_name] ||= Schema.new(
      ar_class: @activerecord_class,
      schema_name: schema_name,
      argument_handler: @argument_handler
    )
  end
end

module Kernel
  def self.plpgsql
    @plpgsql ||= ::PLPGSQL.new
  end

  singleton_class.alias_method :plsql, :plpgsql

  def plpgsql
    ::Kernel.plpgsql
  end

  alias plsql plpgsql
end
