module ActiveRecord::PLPGSQL
  module SetOfScope
    def last_chain_scope(scope, reflection, owner)
      key = reflection.join_primary_key
      foreign_key = reflection.join_foreign_key

      table = reflection.aliased_table
      value = scope.klass.set_of? ? owner[foreign_key] : transform_value(owner[foreign_key])
      scope = apply_scope(scope, table, key, value)

      if reflection.type
        polymorphic_type = transform_value(owner.class.base_class.name)
        scope = apply_scope(scope, table, reflection.type, polymorphic_type)
      end

      scope
    end
  end
end

ActiveRecord::Associations::AssociationScope.prepend(ActiveRecord::PLPGSQL::SetOfScope)
