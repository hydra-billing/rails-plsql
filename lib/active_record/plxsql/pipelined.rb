require 'active_record/plpgsql/set_of'

module ActiveRecord::PLXSQL
  module Pipelined
    extend ActiveSupport::Concern

    include ActiveRecord::PLPGSQL::SetOf

    module ClassMethods
      def pipelined_function=(function)
        self.set_of_function = function
      end

      def pipelined_function
        set_of_function
      end
    end
  end
end
