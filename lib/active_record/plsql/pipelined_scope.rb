module ActiveRecord::PLSQL
  module PipelinedScope
    def last_chain_scope(scope, reflection, owner)
      # join_primary_key/join_foreign_key return an Array for composite keys.
      primary_keys = Array(reflection.join_primary_key)
      foreign_keys = Array(reflection.join_foreign_key)
      table = reflection.aliased_table

      primary_keys.zip(foreign_keys).each do |join_key, foreign_key|
        raw_value = owner._read_attribute(foreign_key)
        # Pipelined arguments are bound as-is; they are not table columns and must not
        # go through the association's value transformation.
        value = pipelined_klass?(scope.klass) ? raw_value : transform_value(raw_value)
        scope = apply_scope(scope, table, join_key, value)
      end

      if reflection.type
        polymorphic_type = transform_value(owner.class.polymorphic_name)
        scope = apply_scope(scope, table, reflection.type, polymorphic_type)
      end

      scope
    end

    def apply_scope(scope, table, key, value)
      if pipelined_klass?(scope.klass)
        pipelined_args = scope.klass.pipelined_arguments_names.map(&:to_sym)
        return scope.where!(key => value) if pipelined_args.include?(key.to_sym)
      end

      super
    end

    private

    def pipelined_klass?(klass)
      klass.respond_to?(:pipelined?) && klass.pipelined?
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
