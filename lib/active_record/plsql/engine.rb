module ActiveRecord::PLSQL
  class Engine < ::Rails::Engine
    initializer 'plsql.load' do
      case ActiveRecord::Base.connection.adapter_name
      in 'PostgreSQL'
        require 'ruby-plpgsql'
        require 'active_record/plxsql/compat'
        require 'active_record/plpgsql/set_of'
        require 'active_record/plpgsql/function_methods'
        require 'active_record/plpgsql/base'
        require 'active_record/plpgsql/set_of_relation'
        require 'active_record/plpgsql/set_of_scope'
        require 'active_record/plpgsql/set_of_assoc_relation'
        require 'plpgsql/log_subscriber'

        PLPGSQL::LogSubscriber.logger = ActiveRecord::Base.logger
      in 'OracleEnhanced'
        require 'ruby-plsql'
        require 'active_record/plsql/pipelined'
        require 'active_record/plsql/procedure_methods'
        require 'active_record/plsql/base'
        require 'active_record/plsql/pipelined_query_methods'
        require 'active_record/plsql/pipelined_relation'
        require 'active_record/plsql/pipelined_scope'
        require 'active_record/plsql/pipelined_assoc_relation'
        require 'active_record/oracle_enhanced_adapter_patch'
        require 'plsql/log_subscriber'
        require 'oracle/named_error'

        PLSQL::LogSubscriber.logger = ActiveRecord::Base.logger
      end
    end
  end
end
