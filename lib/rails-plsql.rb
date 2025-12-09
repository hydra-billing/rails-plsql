if RUBY_ENGINE == 'ruby'
  begin
    require 'oci8'
  rescue LoadError
    # no oci8
  end
end

require 'active_record'
require 'rails/engine'
require 'active_record/plsql/engine'
