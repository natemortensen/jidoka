# frozen_string_literal: true

require_relative "lib/jidoka/version"

Gem::Specification.new do |spec|
  spec.name          = "jidoka"
  spec.version       = Jidoka::VERSION
  spec.authors       = ["Nate Mortensen"]
  spec.summary       = "Reversible Command and Orchestrator patterns for Rails."
  spec.description   = "Encapsulate complex business logic with automatic rollback, validation, and background processing."
  spec.homepage      = "https://github.com/natemortensen/jidoka"
  spec.license       = "MIT"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{\A(?:test|spec|features)/}) }
  end

  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.0.0"

  spec.add_dependency "activejob", ">= 6.0"
  spec.add_dependency "activerecord", ">= 6.0"
  spec.add_dependency "activesupport", ">= 6.0"

  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "pry"
  spec.add_development_dependency "sqlite3"
end
