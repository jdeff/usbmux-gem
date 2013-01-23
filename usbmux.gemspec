# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'usbmux/version'

Gem::Specification.new do |gem|
  gem.name          = "usbmux"
  gem.version       = Usbmux::VERSION
  gem.authors       = ["Jayme Deffenbaugh"]
  gem.email         = ["jdeffenbaugh@me.com"]
  gem.description   = %q{Connecting and communicating to iDevices over USB}
  gem.summary       = %q{Connecting and communicating to iDevices over USB}
  gem.homepage      = "https://github.com/jdeff/usbmux-gem"

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]

  gem.add_dependency 'CFPropertyList'
end
