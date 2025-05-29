require 'active_record/plpgsql/set_of'
require 'active_record/plpgsql/function_methods'
require 'active_record/plpgsql/base'
require 'active_record/plpgsql/set_of_relation'
require 'active_record/plpgsql/set_of_scope'
require 'active_record/plpgsql/set_of_assoc_relation'
# require 'active_record/oracle_enhanced_adapter_patch'
require 'plpgsql/log_subscriber'

module ActiveRecord::PLPGSQL
  class Engine < ::Rails::Engine
    initializer 'plpgsql.logger', after: 'active_record.logger' do
      PLPGSQL::LogSubscriber.logger = ActiveRecord::Base.logger
    end
  end
end
