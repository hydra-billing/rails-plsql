require 'active_record/plpgsql/function_methods'

module ActiveRecord::PLXSQL
  module ProcedureMethods
    extend ActiveSupport::Concern

    include ActiveRecord::PLPGSQL::FunctionMethods

    module ClassMethods
      def plsql_package=(schema)
        self.function_schema = schema
      end

      def plsql_package
        self.function_schema
      end

      def set_create_procedure(procedure, options = {}, &block)
        set_create_method {call_function_method(:create)}
      end

      def set_update_procedure(procedure, options = {}, &block)
        set_update_method {call_function_method(:update)}
      end

      def set_destroy_procedure(procedure, options = {}, &block)
        set_delete_method {call_function_method(:destroy)}
      end

      def procedure_method(*args, **kwargs, &block)
        function_method(*args, **kwargs, &block)
      end

      def procedure_methods
        function_methods
      end

      def procedures_arguments
        functions_arguments
      end
    end

    delegate :procedures_arguments, :procedure_methods, to: 'self.class'
  end
end
