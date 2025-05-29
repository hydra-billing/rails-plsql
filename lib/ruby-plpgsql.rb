class PLPGSQL
  attr_writer :activerecord_class

  def initialize(activerecord_class = nil)
    @activerecord_class = activerecord_class
  end

  class Schema
    attr_reader :schema_name

    alias name schema_name

    def initialize(ar_class:, schema_name:)
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
    end

    def [](function_name)
      Function.new(
        ar_class: @ar_class,
        schema_name: @schema_name,
        function_name: function_name
      )
    end

    private

    def method_missing(name, *args, **kwargs, &block)
      self[name].(*args, **kwargs, &block)
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end

  class Function
    def self.find(plpgsql, schema_name:, function_name:)
      plpgsql.public_send(schema_name)[function_name]
    end

    def initialize(ar_class:, schema_name:, function_name:)
      @ar_class = ar_class
      @schema_name = schema_name
      @function_name = function_name
    end

    def schema_name
      @schema_name
    end

    alias schema schema_name

    def function_name
      @function_name
    end

    alias name function_name

    def call(*args, &_block)
      @ar_class.connection.select_value(
        "select #{@schema_name}.#{@function_name}(#{args_to_string(args)})"
      )
    end

    def overloaded?
      false
    end

    private

    def args_to_string(args)
      args.flat_map do |arg|
        if arg.is_a?(::Hash)
          arg.map do |key, value|
            "#{key} => #{value_to_string(value)}"
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

  private

  def respond_to_missing?(_name, _include_private = false)
    true
  end

  def method_missing(schema_name)
    Schema.new(
      ar_class: @activerecord_class,
      schema_name: schema_name
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
