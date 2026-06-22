# frozen_string_literal: true

require_relative 'lib/solidus_spreedly/version'

Gem::Specification.new do |spec|
  spec.name = 'solidus_spreedly'
  spec.version = SolidusSpreedly::VERSION
  spec.authors = ['Mayur Shah']
  spec.email = 'mrshah@suvie.com'

  spec.summary = 'Solidus payment gateway for Spreedly orchestration.'
  spec.description = 'A Solidus extension that integrates Spreedly as a synchronous, ' \
                     'transaction-token payment gateway, supporting both per-gateway and ' \
                     'workflow (composer) orchestration modes plus a 3DS2 completion path.'
  spec.homepage = 'https://github.com/suvie-eng/solidus_spreedly#readme'
  spec.license = 'BSD-3-Clause'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/suvie-eng/solidus_spreedly'
  spec.metadata['changelog_uri'] = 'https://github.com/suvie-eng/solidus_spreedly/blob/main/CHANGELOG.md'

  spec.required_ruby_version = Gem::Requirement.new('>= 3.0', '< 4')

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  files = Dir.chdir(__dir__) { `git ls-files -z`.split("\x0") }

  spec.files = files.grep_v(%r{^(test|spec|features)/})
  spec.test_files = files.grep(%r{^(test|spec|features)/})
  spec.bindir = "exe"
  spec.executables = files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency 'activemerchant', '~> 1.66'
  spec.add_dependency 'solidus_core', ['>= 4.5', '< 5']
  spec.add_dependency 'solidus_support', '>= 0.12.0'

  spec.add_development_dependency 'solidus_dev_support', '~> 2.12'
  spec.add_development_dependency 'vcr'
  spec.add_development_dependency 'webmock'
end
