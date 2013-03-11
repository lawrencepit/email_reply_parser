# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'version'

Gem::Specification.new do |spec|
  spec.name          = "email_reply_parser"
  spec.version       = EmailReplyParser::VERSION
  spec.authors       = ["Rick Olson"]
  spec.email         = 'technoweenie@gmail.com'
  spec.homepage         = 'http://github.com/github/email_reply_parser'
  spec.description   = "EmailReplyParser is a small library to parse plain text email content to return only the reply."
  spec.summary       = "Email Reply Parser"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]
  spec.rdoc_options  = ["--charset=UTF-8"]
  spec.extra_rdoc_files = %w[README.md LICENSE]

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
end