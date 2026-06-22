# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SolidusSpreedly do
  it 'has a version number' do
    expect(SolidusSpreedly::VERSION).not_to be_nil
  end

  it 'makes ActiveMerchant available to the extension' do
    expect(defined?(ActiveMerchant::Billing::Gateway)).to eq('constant')
  end
end
