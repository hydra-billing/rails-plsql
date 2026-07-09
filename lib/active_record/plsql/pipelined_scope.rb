module ActiveRecord::PLSQL
  module PipelinedScope
    def last_chain_scope(scope, reflection, owner)
      join_keys = reflection.join_keys
      key = join_keys.key
      foreign_key = join_keys.foreign_key

      table = reflection.aliased_table
      value = scope.klass.pipelined? ? owner[foreign_key] : transform_value(owner[foreign_key])
      scope = apply_scope(scope, table, key, value)

      if reflection.type
        polymorphic_type = transform_value(owner.class.base_class.name)
        scope = apply_scope(scope, table, reflection.type, polymorphic_type)
      end

      scope
    end

    def apply_scope(scope, table, key, value)
      if scope.klass.respond_to?(:pipelined?) && scope.klass.pipelined?
        pipelined_args = scope.klass.pipelined_arguments_names.map(&:to_sym)
        return scope.where!(key => value) if pipelined_args.include?(key.to_sym)
      end

      super
    end
  end

  module PipelinedAssociationStatementCache
    private

    def skip_statement_cache?(scope)
      return true if klass.respond_to?(:pipelined?) && klass.pipelined?

      super
    end
  end
end

ActiveRecord::Associations::AssociationScope.prepend(ActiveRecord::PLSQL::PipelinedScope)
ActiveRecord::Associations::Association.prepend(ActiveRecord::PLSQL::PipelinedAssociationStatementCache)
