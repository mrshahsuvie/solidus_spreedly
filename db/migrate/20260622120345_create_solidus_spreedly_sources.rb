# frozen_string_literal: true

class CreateSolidusSpreedlySources < ActiveRecord::Migration[7.0]
  def change
    create_table :solidus_spreedly_sources do |t|
      # The Spreedly vault token for the payment method (used for every
      # money-moving call).
      t.string :payment_method_token
      # The Spreedly payment method kind, e.g. "credit_card".
      t.string :payment_method_type

      # Display-only fields (never used to charge).
      t.string :last_digits
      t.string :card_type
      t.string :month
      t.string :year
      t.string :first_name
      t.string :last_name
      t.string :email

      t.references :payment_method, index: true
      t.references :user, index: true

      t.timestamps
    end

    add_index :solidus_spreedly_sources, :payment_method_token, unique: true
  end
end
