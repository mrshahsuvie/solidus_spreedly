# frozen_string_literal: true

attrs = [:id, :month, :year, :card_type, :last_digits, :payment_method_type]
if @current_user_roles.include?("admin")
  attrs << :payment_method_token
end

json.(payment_source, *attrs)
