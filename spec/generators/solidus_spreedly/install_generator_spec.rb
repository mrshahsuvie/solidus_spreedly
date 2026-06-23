# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "generators/solidus_spreedly/install/install_generator"

RSpec.describe SolidusSpreedly::Generators::InstallGenerator do
  around do |example|
    Dir.mktmpdir { |dir| @destination = dir and example.run }
  end

  def build_generator(opts = {})
    described_class.new([], opts, destination_root: @destination)
  end

  def path(relative)
    File.join(@destination, relative)
  end

  describe "#copy_initializer" do
    it "writes a configured initializer" do
      build_generator.copy_initializer

      initializer = path("config/initializers/solidus_spreedly.rb")
      expect(File).to exist(initializer)
      expect(File.read(initializer)).to include("SolidusSpreedly.configure")
    end
  end

  describe "#copy_frontend_examples" do
    it "copies the example Spreedly Express checkout partial by default" do
      build_generator(frontend: "express").copy_frontend_examples

      partial = path("app/views/spree/checkout/payment/_spreedly.html.erb")
      expect(File).to exist(partial)
      expect(File.read(partial)).to include("data-spreedly-express")
    end

    it 'skips storefront code when frontend is "none"' do
      build_generator(frontend: "none").copy_frontend_examples

      expect(File).not_to exist(path("app/views/spree/checkout/payment/_spreedly.html.erb"))
    end
  end

  describe "#register_classic_assets" do
    it "wires the gem assets into existing classic-frontend manifests" do
      FileUtils.mkdir_p(path("vendor/assets/javascripts/spree/frontend"))
      File.write(path("vendor/assets/javascripts/spree/frontend/all.js"), "//\n")

      build_generator.register_classic_assets

      expect(File.read(path("vendor/assets/javascripts/spree/frontend/all.js")))
        .to include("require spree/frontend/solidus_spreedly")
    end

    it "does nothing when the storefront has no sprockets manifests (headless/starter)" do
      generator = build_generator

      expect { generator.register_classic_assets }.not_to raise_error
      expect(File).not_to exist(path("vendor/assets/javascripts/spree/frontend/all.js"))
    end
  end
end
