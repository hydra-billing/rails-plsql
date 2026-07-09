module ActiveRecord::PLSQL
  module AssociationRelation
    def pipelined_arguments
      klass.pipelined_arguments
    end

    def pipelined_arguments_names
      klass.pipelined_arguments_names
    end

    def pipelined_function_alias
      klass.pipelined_function_alias
    end

    def table_name_with_arguments
      klass.table_name_with_arguments
    end

    def where(opts = :__no_args__, *rest)
      return super() if opts == :__no_args__
      return super unless klass.pipelined? && pipelined_arguments.any?

      pipelined_args = pipelined_arguments_names.map(&:to_sym)
      normalized_opts = normalize_arguments_conditions(opts, pipelined_args)
      return super unless contains_pipelined_arguments?(normalized_opts, pipelined_args)

      pipelined_binds = get_pipelined_arguments(table_binds, normalized_opts)
      where_opts = normalized_opts.reject { |k| pipelined_args.include?(k.to_sym) }

      rel = spawn.from!(
        table_name_with_arguments,
        pipelined_function_alias.to_sym,
        pipelined_binds
      )

      if where_opts.empty? && rest.empty?
        rel
      elsif where_opts.empty?
        rel.where!(*rest)
      elsif where_opts.is_a?(Array)
        rel.where!(*where_opts, *rest)
      else
        rel.where!(where_opts, *rest)
      end
    end

    def where!(opts, *rest)
      return super unless klass.pipelined? && pipelined_arguments.any?

      pipelined_args = pipelined_arguments_names.map(&:to_sym)
      normalized_opts = normalize_arguments_conditions(opts, pipelined_args)
      return super unless contains_pipelined_arguments?(normalized_opts, pipelined_args)

      pipelined_binds = get_pipelined_arguments(table_binds, normalized_opts)
      where_opts = normalized_opts.reject { |k| pipelined_args.include?(k.to_sym) }

      from!(
        table_name_with_arguments,
        pipelined_function_alias.to_sym,
        pipelined_binds
      )

      if where_opts.empty? && rest.empty?
        self
      elsif where_opts.empty?
        super(*rest)
      else
        super(where_opts, *rest)
      end
    end

    def build_from
      if klass.pipelined?
        binds = if from_clause.respond_to?(:table_binds)
          from_clause.table_binds
        else
          []
        end
        if binds.any?
          ActiveRecord::PLSQL::PipelinedRelation.bound_table_for_pipelined(klass, binds)
        else
          klass.arel_table
        end
      else
        super
      end
    end

    def table_binds
      if from_clause.respond_to?(:table_binds)
        from_clause.table_binds
      else
        []
      end
    end

    def from!(value, subquery_name = nil, binds = nil) # :nodoc:
      self.from_clause = ActiveRecord::PLSQL::PipelinedRelation::FromClause.new(value, subquery_name, binds)
      self
    end

    def exec_queries
      return super unless klass.pipelined? && !pipelined_arguments.empty?
      return @records if loaded?

      records = super
      records.each do |record|
        record.found_by_arguments = table_binds if record.respond_to?(:found_by_arguments=)
      end
      records
    end

    private

    # Rails 5.2+ stores binds on the Arel AST. Association default scopes often
    # add ordinary filters first; those must not create FROM TABLE(...(:arg))
    # before the association key supplies the actual pipelined argument.
    def contains_pipelined_arguments?(normalized_opts, pipelined_args)
      normalized_opts.is_a?(Hash) && normalized_opts.any? do |key, _|
        pipelined_args.include?(key.to_sym)
      end
    end

    def get_pipelined_arguments(current, values)
      if values.is_a?(Hash)
        cast_value_method = if ActiveModel::Attribute.respond_to?(:with_cast_value)
          ActiveModel::Attribute.method(:with_cast_value)
        else
          ActiveRecord::Attribute.method(:with_cast_value)
        end

        pipelined_arguments_names.map do |name|
          cast_value_method.call(
            name,
            values.fetch(name.to_sym) do
              cur = current.find { |arg| arg.name.to_sym == name.to_sym }
              cur ? cur.value : nil
            end,
            ActiveRecord::Type.default_value
          )
        end
      else
        current
      end
    end

    def normalize_arguments_conditions(opts, args)
      case opts
      when Hash
        if opts.key?(klass.pipelined_function_name)
          opts[klass.pipelined_function_name].symbolize_keys
        else
          opts.symbolize_keys
        end
      when Arel::Nodes::Equality
        column = opts.left.name.to_sym

        if args.include?(column) && !opts.right.is_a?(Arel::Attributes::Attribute)
          {column => opts.right}
        end
      else
        [opts]
      end
    end
  end
end

ActiveRecord::AssociationRelation.prepend(ActiveRecord::PLSQL::AssociationRelation)
