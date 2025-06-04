require 'active_support/concern'
require 'active_record/connection_adapters/postgresql/procedures'

module ActiveRecord::PLPGSQL
  module FunctionMethods
    extend ActiveSupport::Concern

    class CannotFetchId < StandardError; end

    included do
      include ActiveRecord::PostgreSQLProcedures

      class_attribute :function_schema, :function_method_cache, instance_writer: false
      self.function_schema = nil
      self.function_method_cache = Hash.new do |cache, klass|
        cache[klass] = Hash.new do |methods, method|
          # Inherits procedure methods from base class
          if klass.superclass.respond_to?(:function_methods)
            methods[method] = klass.superclass.function_methods[method]
          else
            nil
          end
        end
      end
    end

    module ClassMethods
      def set_create_function(function, options = {}, &reload_block)
        block ||= proc do |record, result|
          case result
          when Hash
            record.id = result.values.first
          when Numeric
            record.id = result
          else
            raise CannotFetchId, "Couldn't fetch primary key from create procedure (%s) result: %s" %
              [procedure, result.inspect]
          end

          reload_block ? reload_block.call(record) : record.reload

          record.instance_variable_set(:@new_record, true)
          record.id
        end

        function_method(:create, function, options, &block)
        set_create_method {call_function_method(:create)}
      end

      def set_update_function(function, options = {})
        function_method(:update, function, options) do |record|
          record.reload
          record.id
        end
        set_update_method {call_function_method(:update)}
      end

      def set_destroy_function(function, options = {})
        function_method(:destroy, function, options)
        set_delete_method {call_function_method(:destroy)}
      end

      def function_methods
        function_method_cache[self]
      end

      def function_method(method, function_name = method, options = {}, &block)
        function = if ::PLPGSQL::Routine === function_name
          function_name
        else
          find_function(function_name)
        end

        # Raise error if procedure not found
        raise ArgumentError, "Function (%s) not found for method (%s)" % [function_name, method] unless function

        function_methods[method] = {function: function, options: options, block: block}

        unless (instance_methods + private_instance_methods).find {|m| m == method}
          @generated_attribute_methods.class_eval(<<-RUBY, __FILE__, __LINE__ + 1)
            def #{method}(arguments = {}, options = {})
              call_function_method(:#{method}, arguments, options)
            end
          RUBY
        end
      end

      def functions_arguments
        @functions_arguments ||= Hash.new do |cache, function|
          # Always select arguments of first function (overloading not supported)
          cache[function] = Hash[ function.arguments[0].sort_by {|arg| arg[1][:position]} ]
        end
      end

      private

        def find_function(function_name)
          case function_name.to_s.split('.').compact
          in [package, function]
            plpgsql.send(package.to_sym)[function.to_sym]
          in [function]
            if function_schema
              function_schema[function] || ::PLPGSQL::Routine.find(
                plpgsql,
                schema_name: function_schema.name,
                routine_name: function
              )
            else
              raise ArgumentError, "Function (%s) not found" % function_name
            end
          end
        end
    end

    delegate :functions_arguments, :function_methods, to: 'self.class'

    private

      def call_function_method(method, arguments = {}, opts = {})
        function, options, block = function_methods[method].values_at(:function, :options, :block)
        options = options.merge(opts)

        if options[:arguments]
          if arguments.is_a?(Hash)
            arguments = arguments.merge(instance_exec(&options[:arguments]))
          else
            arguments += options[:arguments]
          end
        end

        options[:arguments] = arguments
        call_function(function, options, &block)
      end

      def call_function(function, options = {})
        result = function.exec(*get_function_arguments(function, options))
        if block_given?
          yield(self, result)
        else
          result
        end
      end

      def get_function_arguments(function, options)
        arguments = options[:arguments]
        arguments = arguments.dup if arguments.duplicable?

        if Hash === arguments
          arguments.symbolize_keys!
          arguments_metadata = procedures_arguments[procedure]
          # throw away unnecessary arguments
          [arguments.select {|k,_| arguments_metadata[k]}]
        else
          arguments
        end
      end
  end
end
