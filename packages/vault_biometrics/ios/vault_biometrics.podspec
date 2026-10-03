Pod::Spec.new do |s|
  s.name             = 'vault_biometrics'
  s.version          = '0.1.0'
  s.summary          = 'Face ID / Touch ID unlock for the hidden content vault.'
  s.homepage         = 'https://github.com/moonfin'
  s.license          = { :type => 'GPL-2.0' }
  s.author           = 'Moonfin'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.frameworks       = 'LocalAuthentication'
  s.platform         = :ios, '12.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
