# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusSpreedly::PaymentMethodResponse do
  describe ".from_raw" do
    it "succeeds when payment_method is present and expectations match" do
      raw = {
        payment_method: {
          token: "PMT123",
          managed: false,
          storage_state: "retained",
          errors: []
        }
      }.to_json

      response = described_class.from_raw(raw, expect: {managed: false, storage_state: "retained"})

      expect(response).to be_success
      expect(response.message).to eq("OK")
      expect(response.payment_method_token).to eq("PMT123")
      expect(response.payment_method["managed"]).to eq(false)
      expect(response.error_code).to be_nil
    end

    it "casts boolean expectations" do
      raw = {payment_method: {token: "PMT123", managed: "true", errors: []}}.to_json

      response = described_class.from_raw(raw, expect: {managed: true})

      expect(response).to be_success
    end

    it "fails when an expectation does not match" do
      raw = {payment_method: {token: "PMT123", managed: true, errors: []}}.to_json

      response = described_class.from_raw(raw, expect: {managed: false})

      expect(response).not_to be_success
    end

    it "fails on nested payment_method errors" do
      raw = {
        payment_method: {
          token: "PMT123",
          errors: [{key: "errors.invalid", message: "bad"}]
        }
      }.to_json

      response = described_class.from_raw(raw)

      expect(response).not_to be_success
      expect(response.error_code).to eq("errors.invalid")
      expect(response.message).to eq("bad")
    end

    it "fails on top-level Spreedly errors" do
      raw = {
        errors: [{key: "errors.not_found", message: "Unable to find the specified payment method."}]
      }.to_json

      response = described_class.from_raw(raw, expect: {managed: false})

      expect(response).not_to be_success
      expect(response.error_code).to eq("errors.not_found")
      expect(response.message).to eq("Unable to find the specified payment method.")
    end

    it "handles invalid JSON" do
      response = described_class.from_raw("not-json")

      expect(response).not_to be_success
      expect(response.message).to include("Invalid response received from Spreedly")
    end
  end
end
