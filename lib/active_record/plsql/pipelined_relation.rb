module ActiveRecord::PLSQL
  class PipelinedRelation < ActiveRecord::Relation
    # The query behaviour lives in PipelinedQueryMethods, shared with the module
    # prepended onto AssociationRelation. Do NOT include Pipelined::ClassMethods here:
    # its methods read @pipelined_function from the receiver, which is nil on a relation.
    include PipelinedQueryMethods

    class FromClause < ActiveRecord::Relation::FromClause
      def initialize(value, name, binds = nil)
        super(value, name)

        @binds = binds
      end

      def binds
        @binds || super
      end

      def table_binds
        @binds || []
      end
    end

    attr_accessor :pipelined_arguments_values

    def pipelined?
      klass.pipelined?
    end

    def pipelined_function
      klass.pipelined_function
    end

    def table
      if klass.pipelined?
        klass.arel_table
      else
        super
      end
    end

    # Build an Arel::Table with a BoundSqlLiteral that embeds FROM binds
    # into the Arel AST so Rails 7.2 compiled binds include pipelined function arguments.
    def self.bound_table_for_pipelined(klass, binds)
      named_binds = {}
      klass.pipelined_arguments_names.each_with_index do |name, i|
        named_binds[name.to_sym] = binds[i] if i < binds.length
      end
      sql = klass.table_name_with_arguments
      bound_literal = Arel::Nodes::BoundSqlLiteral.new(sql, nil, named_binds)
      Arel::Table.new(bound_literal, as: klass.pipelined_function_alias, klass: klass)
    end
  end
end

# PipelinedRelation is instantiated directly instead of through
# Delegation#relation_class_for, so it never gets the per-model delegate class that
# Rails builds for ordinary relations. Without this, model scopes and class methods
# are not reachable from a pipelined relation.
unless ActiveRecord::PLSQL::PipelinedRelation < ActiveRecord::Delegation::ClassSpecificRelation
  ActiveRecord::PLSQL::PipelinedRelation.include(ActiveRecord::Delegation::ClassSpecificRelation)
end
