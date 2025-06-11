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
      routine_type = @ar_class.connection.select_value(<<-SQL)
        SELECT routine_type
        FROM information_schema.routines
        WHERE routine_schema = '#{@schema_name.to_s.downcase}'
        AND routine_name = '#{normalize_function_name(name)}'
      SQL

      case routine_type
      when 'PROCEDURE'
        Procedure.new(
          ar_class: @ar_class,
          schema_name: @schema_name,
          routine_name: name,
          argument_handler: @argument_handler
        )
      when 'FUNCTION'
        Function.new(
          ar_class: @ar_class,
          schema_name: @schema_name,
          routine_name: name,
          argument_handler: @argument_handler
        )
      else
        UnknownRoutine.new(
          ar_class: @ar_class,
          schema_name: @schema_name,
          routine_name: name,
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

    def initialize(ar_class:, schema_name:, routine_name:, argument_handler:)
      @ar_class = ar_class
      @schema_name = schema_name
      @routine_name = routine_name
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

    private

    def args_to_string(args)
      args.flat_map do |arg|
        if arg.is_a?(::Hash)
          arg.map do |key, value|
            arg_name = @argument_handler.call(self, key)
            "#{arg_name} => #{value_to_string(value)}"
          end
        else
          [value_to_string(arg)]
        end
      end.join(', ')
    end

    def value_to_string(value)
      if value.is_a?(::String)
        "'#{value}'"
      elsif value.nil?
        'null'
      else
        value.to_s
      end
    end
  end

  class Function < Routine
    def call(*args, &_block)
      @ar_class.connection.select_value(
        "select #{@schema_name}.#{name}(#{args_to_string(args)})"
      )
    end
  end

  class Procedure < Routine
    def call(*args, &_block)
      @ar_class.connection.execute(
        "call #{@schema_name}.#{name}(#{args_to_string(args)})"
      )
    end
  end

  class UnknownRoutine < Routine
    def call(*args, &_block)
      raise "Unknown routine: #{@schema_name}.#{@routine_name}"
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
