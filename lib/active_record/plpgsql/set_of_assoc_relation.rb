module ActiveRecord::PLPGSQL
  module AssociationRelation
    def build_from
      if klass.set_of?
        klass.arel_table
      else
        super
      end
    end
  end
end

ActiveRecord::AssociationRelation.prepend(ActiveRecord::PLPGSQL::AssociationRelation)
