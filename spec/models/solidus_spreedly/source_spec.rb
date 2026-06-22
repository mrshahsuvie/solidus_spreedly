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
