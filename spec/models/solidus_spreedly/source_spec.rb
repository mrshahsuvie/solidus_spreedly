# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusSpreedly::Source do
  subject(:source) { build(:solidus_spreedly_source) }

  it "is valid with a payment method token" do
    expect(source).to be_valid
  end

  it "requires a payment method token" do
    source.payment_method_token = nil
    expect(source).not_to be_valid
    expect(source.errors[:payment_method_token]).to be_present
  end

  describe "#reusable?" do
    it "is reusable when a vault token is present" do
      expect(source.reusable?).to be(true)
    end

    it "is not reusable without a vault token" do
      source.payment_method_token = nil
      expect(source.reusable?).to be(false)
    end
  end

  describe "#display_number" do
    it "masks all but the last four digits" do
      source.last_digits = "4242"
      expect(source.display_number).to eq("XXXX-XXXX-XXXX-4242")
    end

    it "pads when fewer than four digits are known" do
      source.last_digits = "42"
      expect(source.display_number).to eq("XXXX-XXXX-XXXX-XX42")
    end
  end

  describe "Spree::CreditCard-style aliases" do
    it "aliases last_4 and cc_type" do
      expect(source.last_4).to eq(source.last_digits)
      expect(source.cc_type).to eq(source.card_type)
    end
  end

  describe "#actions" do
    it "supports capture, void and credit" do
      expect(source.actions).to contain_exactly("capture", "void", "credit")
    end
  end

  describe "#can_void?" do
    let(:payment_method) { create(:solidus_spreedly_payment_method) }
    let(:source) { create(:solidus_spreedly_source, payment_method: payment_method) }

    def build_payment(state:)
      create(
        :payment,
        payment_method: payment_method,
        source: source,
        state: state,
        response_code: "TXN123",
        amount: 10
      )
    end

    def store_purchase(payment, gateway_type:)
      payment.log_entries.create!(
        parsed_details: ActiveMerchant::Billing::Response.new(
          true,
          "Succeeded!",
          {
            "transaction" => {
              "succeeded" => true,
              "token" => payment.response_code,
              "transaction_type" => "Purchase",
              "gateway_type" => gateway_type
            }
          },
          authorization: payment.response_code
        )
      )
    end

    it "returns false for a completed Stripe purchase" do
      payment = build_payment(state: "completed")
      store_purchase(payment, gateway_type: "stripe_payment_intents")

      expect(source.can_void?(payment)).to be(false)
    end

    it "returns true for a completed Braintree purchase" do
      payment = build_payment(state: "completed")
      store_purchase(payment, gateway_type: "braintree")

      expect(source.can_void?(payment)).to be(true)
    end

    it "returns true for a pending payment" do
      payment = build_payment(state: "pending")

      expect(source.can_void?(payment)).to be(true)
    end

    it "returns true for a completed payment with no log entry" do
      payment = build_payment(state: "completed")

      expect(source.can_void?(payment)).to be(true)
    end
  end

  describe "persistence and associations" do
    it "persists and is associated to a payment method" do
      source.save!

      expect(source.reload.payment_method).to be_a(SolidusSpreedly::Gateway)
    end
  end

  describe ".with_payment_profile" do
    it "returns only sources carrying a vault token" do
      with_token = create(:solidus_spreedly_source)

      expect(described_class.with_payment_profile).to include(with_token)
    end
  end

  it "is the payment_source_class of the gateway" do
    expect(SolidusSpreedly::Gateway.new.payment_source_class).to eq(described_class)
  end
end
