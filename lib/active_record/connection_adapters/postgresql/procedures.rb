# frozen_string_literal: true

require "active_support"

module ActiveRecord
  module PostgreSQLProcedures
    module ClassMethods
      def set_create_method(&block)
        self.custom_create_method = block
      end

      def set_update_method(&block)
        self.custom_update_method = block
      end

      def set_delete_method(&block)
        self.custom_delete_method = block
      end
    end

    def self.included(base)
      base.class_eval do
        extend ClassMethods
        class_attribute :custom_create_method
        class_attribute :custom_update_method
        class_attribute :custom_delete_method
      end
    end

    def destroy
      if self.class.custom_delete_method
        with_transaction_returning_status do
          run_callbacks(:destroy) { destroy_using_custom_method }
        end
      else
        super
      end
    end

    private
      def _create_record
        if self.class.custom_create_method
          run_callbacks(:create) do
            if self.record_timestamps
              current_time = current_time_from_proper_timezone

              all_timestamp_attributes_in_model.each do |column|
                if respond_to?(column) && respond_to?("#{column}=") && self.send(column).nil?
                  write_attribute(column.to_s, current_time)
                end
              end
            end
            create_using_custom_method
          end
        else
          super
        end
      end

      def create_using_custom_method
        log_custom_method("custom create method", "#{self.class.name} Create") do
          self.id = instance_eval(&self.class.custom_create_method)
        end
        @new_record = false
        @persisted = true
        id
      end

      def _update_record(attribute_names = @attributes.keys)
        if self.class.custom_update_method
          run_callbacks(:update) do
            if should_record_timestamps?
              current_time = current_time_from_proper_timezone

              timestamp_attributes_for_update_in_model.each do |column|
                column = column.to_s
                next if will_save_change_to_attribute?(column)
                write_attribute(column, current_time)
              end
            end
            if partial_updates?
              update_using_custom_method(changed | (attributes.keys & self.class.columns.select { |column| column.is_a?(Type::Serialized) }))
            else
              update_using_custom_method(attributes.keys)
            end
          end
        else
          super
        end
      end

      def update_using_custom_method(attribute_names)
        return 0 if attribute_names.empty?
        log_custom_method("custom update method with #{self.class.primary_key}=#{self.id}", "#{self.class.name} Update") do
          instance_eval(&self.class.custom_update_method)
        end
        1
      end

      def destroy_using_custom_method
        unless new_record? || @destroyed
          log_custom_method("custom delete method with #{self.class.primary_key}=#{self.id}", "#{self.class.name} Destroy") do
            instance_eval(&self.class.custom_delete_method)
          end
        end

        @destroyed = true
        freeze
      end

      def log_custom_method(*args, &block)
        self.class.connection.send(:log, *args, &block)
      end

      alias_method :update_record, :_update_record if private_method_defined?(:_update_record)
      alias_method :create_record, :_create_record if private_method_defined?(:_create_record)
  end
end
