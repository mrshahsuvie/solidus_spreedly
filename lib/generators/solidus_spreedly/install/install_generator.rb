# frozen_string_literal: true

require "rails/generators"

module SolidusSpreedly
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      class_option :auto_run_migrations, type: :boolean, default: false
      class_option :frontend,
        type: :string,
        enum: %w[express none],
        default: "express",
        desc: "Copy example Spreedly Express checkout assets (express) or skip storefront code (none)"

      def self.exit_on_failure?
        true
      end

      def copy_initializer
        template "initializer.rb", "config/initializers/solidus_spreedly.rb"
      end

      # Solidus discourages extensions from shipping storefront code, since
      # storefronts vary wildly (classic ERB, Starter Frontend, headless, ...).
      # We therefore copy a *self-contained example* of a Spreedly Express
      # integration that stores can adapt, rather than wiring it in for them.
      def copy_frontend_examples
        return if options[:frontend] == "none"

        say_status :example,
          "Copying example Spreedly Express checkout assets. " \
          "Per the Solidus extension guide these are examples to adapt to your storefront.",
          :blue

        directory "app", "app"
      end

      # Register the gem's sprockets assets, but only for classic
      # (solidus_frontend) storefronts that actually have these manifests.
      def register_classic_assets
        register_javascript("spree/frontend/all.js", "spree/frontend/solidus_spreedly")
        register_javascript("spree/backend/all.js", "spree/backend/solidus_spreedly")
        register_stylesheet("spree/frontend/all.css", "spree/frontend/solidus_spreedly")
        register_stylesheet("spree/backend/all.css", "spree/backend/solidus_spreedly")
      end

      def add_migrations
        run "bin/rails railties:install:migrations FROM=solidus_spreedly"
      end

      def run_migrations
        run_migrations = options[:auto_run_migrations] ||
          ["", "y", "Y"].include?(ask("Would you like to run the migrations now? [Y/n]"))
        if run_migrations
          run "bin/rails db:migrate"
        else
          say_status :skip, "Skipping bin/rails db:migrate, don't forget to run it!", :yellow
        end
      end

      private

      def register_javascript(manifest, require_path)
        path = "vendor/assets/javascripts/#{manifest}"
        return unless manifest_exists?(path)

        append_file path, "//= require #{require_path}\n"
      end

      def register_stylesheet(manifest, require_path)
        path = "vendor/assets/stylesheets/#{manifest}"
        return unless manifest_exists?(path)

        inject_into_file path, " *= require #{require_path}\n", before: %r{\*/}, verbose: true
      end

      def manifest_exists?(relative_path)
        File.exist?(File.join(destination_root, relative_path))
      end
    end
  end
end
