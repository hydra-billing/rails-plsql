module ActiveRecord::PLSQL
  class PipelinedRelation < ActiveRecord::Relation
    # Metadata is delegated to @klass below; do NOT include Pipelined::ClassMethods
    # because its methods read @pipelined_function from self, which is nil on relation.

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

    # Delegate pipelined metadata methods to the model class,
    # because the relation instance does not have @pipelined_function set.
    # These methods from ActiveRecord::PLSQL::Pipelined::ClassMethods
    # read @pipelined_function from the receiver, which is nil on the relation.
    def pipelined_arguments
      @klass.pipelined_arguments
    end

    def pipelined_arguments_names
      @klass.pipelined_arguments_names
    end

    def pipelined_function_alias
      @klass.pipelined_function_alias
    end

    def table_name_with_arguments
      @klass.table_name_with_arguments
    end

    def pipelined?
      @klass.pipelined?
    end

    def pipelined_function
      @klass.pipelined_function
    end

    def where(opts, *rest)
      return super unless @klass.pipelined? && pipelined_arguments.any?

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
      return super unless @klass.pipelined? && pipelined_arguments.any?

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

    def get_pipelined_arguments(current, values)
      if values.is_a?(Hash)
        # Rails 7.2 moved with_cast_value from ActiveRecord::Attribute to ActiveModel::Attribute
        cast_value_method = if ActiveModel::Attribute.respond_to?(:with_cast_value)
          ActiveModel::Attribute.method(:with_cast_value)
        else
          ActiveRecord::Attribute.method(:with_cast_value)
        end
        pipelined_arguments_names.map do |name|
          cast_value_method.call(
            name,
            values.fetch(name.to_sym) {
              cur = current.find { |arg| arg.name.to_sym == name.to_sym }
              cur ? cur.value : nil
            },
            ActiveRecord::Type.default_value
          )
        end
      else
        current
      end
    end

    def table_binds
      if from_clause.is_a?(FromClause)
        from_clause.table_binds
      else
        []
      end
    end

    def build_from
      if @klass.pipelined?
        binds = table_binds
        if binds.any?
          self.class.bound_table_for_pipelined(@klass, binds)
        else
          @klass.arel_table
        end
      else
        super
      end
    end

    def table
      if @klass.pipelined?
        @klass.arel_table
      else
        super
      end
    end

    def from!(value, subquery_name = nil, binds = nil) # :nodoc:
      self.from_clause = FromClause.new(value, subquery_name, binds)
      self
    end

    def exec_queries
      return super unless @klass.pipelined? && !pipelined_arguments.empty?
      return @records if loaded?
      records = super
      records.each { |record| record.found_by_arguments = table_binds }
      records
    end

    protected

    # Rails 5.2+ expects bind values for Arel queries to live on the AST.
    # Keep ordinary filters/default scopes on the regular Relation path so they
    # don't create an early FROM TABLE(...(:arg)) without AST-bound arg values.
    def contains_pipelined_arguments?(normalized_opts, pipelined_args)
      normalized_opts.is_a?(Hash) && normalized_opts.any? do |key, _|
        pipelined_args.include?(key.to_sym)
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
          { column => opts.right }
        end
      else
        [opts]
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
