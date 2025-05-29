if RUBY_ENGINE == 'ruby'
  begin
    require 'oci8'
  rescue LoadError
    # no oci8
  end
end
require 'active_record'

begin
  require 'activerecord-oracle_enhanced-adapter'
  require 'ruby-plsql'
  require 'oracle/named_error'
  require 'rails/engine'
  require 'active_record/plsql/engine'
rescue LoadError
  require 'rails-plpgsql'
end
