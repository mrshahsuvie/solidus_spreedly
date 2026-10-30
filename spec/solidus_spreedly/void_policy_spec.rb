# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusSpreedly::VoidPolicy do
  subject(:policy) { described_class.new }

  def transaction(attrs = {})
    {
      "succeeded" => true,
      "transaction_type" => "Purchase",
      "gateway_type" => "braintree"
    }.merge(attrs)
  end

  describe "configuration" do
    it "is the default void policy class" do
      expect(SolidusSpreedly.config.void_policy_class).to eq("SolidusSpreedly::VoidPolicy")
    end
  end

  describe "#voidable?" do
    it "returns false when the transaction is missing" do
      expect(policy.voidable?(nil)).to be(false)
      expect(policy.voidable?({})).to be(false)
    end

    it "returns false when the transaction did not succeed" do
      expect(policy.voidable?(transaction("succeeded" => false))).to be(false)
    end

    it "returns false for a void" do
      expect(policy.voidable?(transaction("transaction_type" => "Void"))).to be(false)
    end

    it "returns false for a credit" do
      expect(policy.voidable?(transaction("transaction_type" => "Credit"))).to be(false)
    end

    it "returns false for a succeeded Stripe purchase" do
      expect(
        policy.voidable?(transaction("gateway_type" => "stripe", "transaction_type" => "Purchase"))
      ).to be(false)
    end

    it "returns false for a succeeded Stripe PaymentIntents purchase" do
      expect(
        policy.voidable?(
          transaction("gateway_type" => "stripe_payment_intents", "transaction_type" => "Purchase")
        )
      ).to be(false)
    end

    it "returns true for a succeeded Stripe authorization" do
      expect(
        policy.voidable?(
          transaction("gateway_type" => "stripe_payment_intents", "transaction_type" => "Authorization")
        )
      ).to be(true)
    end

    it "returns true for a succeeded Braintree purchase" do
      expect(policy.voidable?(transaction("gateway_type" => "braintree"))).to be(true)
    end

    it "returns true when gateway_type is blank" do
      expect(policy.voidable?(transaction("gateway_type" => nil))).to be(true)
      expect(policy.voidable?(transaction("gateway_type" => ""))).to be(true)
    end

    it "returns true for an unknown gateway purchase" do
      expect(policy.voidable?(transaction("gateway_type" => "test"))).to be(true)
    end
  end
end
