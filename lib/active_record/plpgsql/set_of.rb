require 'active_support/concern'

module ActiveRecord::PLPGSQL
  module SetOf
    extend ActiveSupport::Concern

    class SetOfFunctionError < ActiveRecord::ActiveRecordError; end

    class SetOfFunctionTableName < Arel::Nodes::SqlLiteral
      alias_method :to_s, :itself
    end

    included do
      self.set_of_function = nil
    end

    module DisableBinding
      def can_be_bound?(*)
        false
      end
    end

    module ClassMethods
      def set_of_arguments
        raise SetOfFunctionError, "Set of function wasn't set" unless set_of?
        @set_of_arguments ||= get_set_of_arguments
      end

      def set_of_arguments_names
        set_of_arguments.map(&:name)
      end

      def set_of_function
        @set_of_function
      end

      alias set_of? set_of_function

      def set_of_function=(function)
        case function
        when String, Symbol
          # Name without schema expected
          function_name = function.to_s.split('.').map(&:downcase).map(&:to_sym)
          case function_name.size
          when 2
            set_of_function = plsql.send(function_name.first)[function_name.second]
          when 1
            set_of_function = PLPGSQL::SetOfFunction.find(plsql, function_name.first)
          else
            raise ArgumentError, 'Setting schema via string not supported yet'
          end
          raise ArgumentError, 'Set of function not found by string: %s' % function unless set_of_function
        when ::PLPGSQL::Function, nil
          set_of_function = function
        else
          raise ArgumentError, 'Unsupported type of function: %s' % function.inspect
        end

        if set_of_function && set_of_function.overloaded?
          raise ArgumentError, 'Overloaded functions are not supported yet'
        end

        @set_of_function = set_of_function
        @set_of_arguments = nil
        # @table_name = set_of_function_name if @set_of_function
      end

      def set_of_function_name
        return @full_function_name if defined? @full_function_name
        schema_name, function_name = @set_of_function.schema, @set_of_function.name
        @full_function_name = [schema_name, function_name].compact.join('.')
      end

      def arel_table
        if set_of?
          @arel_table ||= Arel::Table.new(
            table_name_with_arguments,
            as: set_of_function_alias
          )
        else
          super
        end
      end

      def set_of_function_alias
        # GET_USER_BY_NAME => GUBN
        @set_of_function.routine_name.scan(/^\w|_\w/).join('').gsub('_', '')
      end

      def table_name_with_arguments
        @table_name_with_arguments ||= SetOfFunctionTableName.new(
          "%s(%s)" % [table_name, set_of_arguments.map{|a| ":#{a.name}"}.join(',')]
        )
      end

      def column_names
        if set_of?
          set_of_function.columns.map(&:name)
        else
          super
        end
      end

      def columns_hash
        if set_of?
          set_of_function.columns.to_h { |col| [col.name, col] }
        else
          super
        end
      end

      def table_exist?
        set_of? || super
      end

      def predicate_builder
        if set_of?
          @_predicate_builder ||= super.extend(DisableBinding)
        else
          super
        end
      end

      private

      def get_set_of_arguments
        # Always select arguments of first function (overloading not supported)
        arguments_metadata = set_of_function.arguments[0].sort_by {|arg| arg[1][:position]}
        arguments_metadata.map(&:first)
        # arguments_metadata.map do |name, argument|
        #   ActiveRecord::ConnectionAdapters::PostgreSQLAdapter::Column.new(
        #     name.to_s, nil, fetch_type_metadata(argument[:data_type]), set_of_function_name
        #   )
        # end
      end

      def fetch_type_metadata(sql_type, virtual = nil)
        ActiveRecord::ConnectionAdapters::OracleEnhanced::TypeMetadata.new(sql_type)
      end

      def relation
        return super unless set_of?
        @relation ||= SetOfRelation.new(self, table: arel_table, predicate_builder: predicate_builder)
      end
    end

    delegate :set_of?, to: 'self.class'

    attr_accessor :found_by_arguments

    def reload(options = nil)
      return super unless set_of? && (found_by_arguments.present? || options)

      clear_aggregation_cache
      clear_association_cache

      fresh_object = self.class.unscoped do
        args = try_get_arguments(found_by_arguments).merge(options || {})
        relation = self.class.where(
          **args,
          self.class.primary_key => id,
        )

        relation.to_a[0]
      end

      @attributes = fresh_object.instance_variable_get("@attributes")
      @new_record = false

      @changed_attributes = ActiveSupport::HashWithIndifferentAccess.new
      self
    end

    private

    def try_get_arguments(arguments)
      if arguments
        arguments.each_with_object({}) { |arg, hash| hash[arg.name.to_sym] = arg.value }
      else
        {}
      end
    end
  end
end
