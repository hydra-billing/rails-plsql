# Associations pointing at a pipelined model produce an AssociationRelation rather
# than a PipelinedRelation, so the same query behaviour is prepended here.
# PipelinedQueryMethods no-ops for any model that is not pipelined.
ActiveRecord::AssociationRelation.prepend(ActiveRecord::PLSQL::PipelinedQueryMethods)
