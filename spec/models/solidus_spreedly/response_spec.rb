# frozen_string_literal: true

require "spec_helper"

RSpec.describe SolidusSpreedly::Response do
  def am_response(succeeded:, params:)
    ActiveMerchant::Billing::Response.new(
      succeeded,
      "message",
      params,
      authorization: "TXN123",
      test: true
    )
  end

  describe ".from_response" do
    it "adapts a plain ActiveMerchant response, preserving its fields" do
      original = am_response(
        succeeded: true,
        params: {"transaction" => {"state" => "succeeded"}}
      )

      response = described_class.from_response(original)

      expect(response).to be_a(described_class)
      expect(response).to be_success
      expect(response.authorization).to eq("TXN123")
      expect(response.state).to eq("succeeded")
    end
  end

  describe "#state and #pending?" do
    it "reads the transaction state" do
      response = described_class.new(true, "ok", {"transaction" => {"state" => "pending"}})

      expect(response.state).to eq("pending")
      expect(response.pending?).to be(true)
    end

    it "falls back to a top-level state" do
      response = described_class.new(true, "ok", {"state" => "succeeded"})

      expect(response.state).to eq("succeeded")
      expect(response.pending?).to be(false)
    end
  end

  describe "#checkout_url" do
    it "surfaces a challenge checkout url for pending transactions" do
      response = described_class.new(
        true,
        "ok",
        {"transaction" => {"state" => "pending", "checkout_url" => "https://example.test/3ds"}}
      )

      expect(response.checkout_url).to eq("https://example.test/3ds")
    end
  end

  describe "#friendly_message" do
    it "humanizes a known state via I18n" do
      response = described_class.new(false, "raw", {"transaction" => {"state" => "gateway_processing_failed"}})

      expect(response.friendly_message).to eq("Gateway processing failed")
    end

    it "falls back to the raw message when there is no state" do
      response = described_class.new(true, "raw message", {})

      expect(response.friendly_message).to eq("raw message")
    end
  end
end
