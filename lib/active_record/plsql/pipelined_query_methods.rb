module ActiveRecord::PLSQL
  # Query behaviour shared by the two relation flavours that can sit in front of a
  # pipelined function:
  #
  #   * PipelinedRelation, a Relation subclass built directly by Pipelined#relation
  #   * ActiveRecord::AssociationRelation, which this module is prepended onto so
  #     associations pointing at a pipelined model behave the same way
  #
  # A pipelined function is addressed as FROM TABLE(fn(:arg)), so its arguments are
  # not columns and cannot go through the normal where-clause machinery. Conditions
  # naming an argument are peeled off and turned into FROM binds; everything else is
  # handed back to ActiveRecord untouched.
  module PipelinedQueryMethods
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

    def where(*args)
      return super if args.empty? || !pipelined_query?

      opts, *rest = args
      pipelined_args = pipelined_argument_symbols
      normalized_opts = normalize_arguments_conditions(opts, pipelined_args)
      return super unless contains_pipelined_arguments?(normalized_opts, pipelined_args)

      rel = spawn.from!(
        table_name_with_arguments,
        pipelined_function_alias.to_sym,
        get_pipelined_arguments(table_binds, normalized_opts)
      )
      where_opts = reject_pipelined_arguments(normalized_opts, pipelined_args)

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
      return super unless pipelined_query?

      pipelined_args = pipelined_argument_symbols
      normalized_opts = normalize_arguments_conditions(opts, pipelined_args)
      return super unless contains_pipelined_arguments?(normalized_opts, pipelined_args)

      from!(
        table_name_with_arguments,
        pipelined_function_alias.to_sym,
        get_pipelined_arguments(table_binds, normalized_opts)
      )
      where_opts = reject_pipelined_arguments(normalized_opts, pipelined_args)

      if where_opts.empty? && rest.empty?
        self
      elsif where_opts.empty?
        super(*rest)
      else
        super(where_opts, *rest)
      end
    end

    def build_from
      return super unless pipelined_model?

      binds = table_binds
      if binds.any?
        PipelinedRelation.bound_table_for_pipelined(klass, binds)
      else
        klass.arel_table
      end
    end

    def table_binds
      from_clause.respond_to?(:table_binds) ? from_clause.table_binds : []
    end

    def from!(value, subquery_name = nil, binds = nil) # :nodoc:
      self.from_clause = PipelinedRelation::FromClause.new(value, subquery_name, binds)
      self
    end

    def exec_queries
      return super unless pipelined_query?
      return @records if loaded?

      records = super
      records.each do |record|
        record.found_by_arguments = table_binds if record.respond_to?(:found_by_arguments=)
      end
      records
    end

    private

    # This module is prepended onto every AssociationRelation, so it also runs for
    # models that never included Pipelined and do not answer #pipelined? at all.
    def pipelined_model?
      klass.respond_to?(:pipelined?) && klass.pipelined?
    end

    def pipelined_query?
      pipelined_model? && pipelined_arguments.any?
    end

    def pipelined_argument_symbols
      pipelined_arguments_names.map(&:to_sym)
    end

    def reject_pipelined_arguments(normalized_opts, pipelined_args)
      normalized_opts.reject { |key| pipelined_args.include?(key.to_sym) }
    end

    # Bind values for Arel live on the AST. Association default scopes tend to add
    # ordinary filters first, and those must not build a FROM TABLE(...(:arg)) before
    # the association key has supplied the actual argument value.
    def contains_pipelined_arguments?(normalized_opts, pipelined_args)
      normalized_opts.is_a?(Hash) && normalized_opts.any? do |key, _|
        pipelined_args.include?(key.to_sym)
      end
    end

    def get_pipelined_arguments(current, values)
      return current unless values.is_a?(Hash)

      pipelined_arguments_names.map do |name|
        attribute_factory.call(
          name,
          values.fetch(name.to_sym) do
            cur = current.find { |arg| arg.name.to_sym == name.to_sym }
            cur ? cur.value : nil
          end,
          ActiveRecord::Type.default_value
        )
      end
    end

    # Rails 7.2 moved with_cast_value from ActiveRecord::Attribute to ActiveModel::Attribute.
    def attribute_factory
      if ActiveModel::Attribute.respond_to?(:with_cast_value)
        ActiveModel::Attribute.method(:with_cast_value)
      else
        ActiveRecord::Attribute.method(:with_cast_value)
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

        # only simple types for now
        if args.include?(column) && !opts.right.is_a?(Arel::Attributes::Attribute)
          {column => opts.right}
        end
      else
        [opts]
      end
    end
  end
end
