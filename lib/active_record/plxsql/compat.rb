require 'plpgsql/named_error'
require 'active_record/plxsql/pipelined'
require 'active_record/plxsql/procedure_methods'

module ActiveRecord
  PLSQL = ActiveRecord::PLXSQL
end

module Oracle
  NamedError = PLPGSQL::NamedError
end
