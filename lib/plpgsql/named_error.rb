class PLPGSQL
  class NamedError < ::StandardError
    class_attribute :error_code, instance_writer: false

    class << self
      CLASS_NAME=  /PG::RaiseException|PG::ServerError/

      def ===(error)
        if error.respond_to?(:message)
          error.message.start_with?(CLASS_NAME) &&
            error.message.match?(/ERROR:  \[-?#{error_code}\]/)
        else
          false
        end
      end

      def define_exception(class_name, error_code)
        class_eval(<<-RUBY, __FILE__, __LINE__ + 1)
          class ::#{class_name} < PLPGSQL::NamedError
            self.error_code = #{error_code}
          end
        RUBY
      end
    end
  end
end
