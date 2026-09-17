Pod::Spec.new do |spec|
  spec.name = 'RishLocalRuntime'
  spec.version = '0.1.0'
  spec.summary = 'Local DSH substrate proof backed by rish.'
  spec.homepage = 'https://github.com/ZSeven-W/rish'
  spec.license = { type: 'MIT' }
  spec.author = 'ZSeven'
  spec.source = { path: '.' }
  spec.platform = :ios, '15.1'
  spec.source_files = 'Sources/**/*.{h,m,mm}'
  spec.vendored_frameworks = [
    'Vendor/rish_ffi.xcframework',
    'Vendor/rish_agent_core.xcframework',
    'Vendor/libgit2.xcframework',
    'Vendor/libssh2.xcframework',
    'Vendor/libcrypto.xcframework',
  ]
  spec.preserve_paths = ['include/rish.h']
  guest_cgi_enabled = ENV.fetch('RISH_IOS_GUEST_CGI_ENABLED', '0')
  unless %w[0 1].include?(guest_cgi_enabled)
    raise 'RISH_IOS_GUEST_CGI_ENABLED must be 0 or 1'
  end
  spec.pod_target_xcconfig = {
    # libgit2 is a vendored static XCFramework. CocoaPods exposes its link
    # input late, so add both immutable header roots explicitly for compile
    # phases on device and simulator.
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/include" "${PODS_TARGET_SRCROOT}/Vendor/rish_agent_core.xcframework/ios-arm64/Headers" "${PODS_TARGET_SRCROOT}/Vendor/rish_agent_core.xcframework/ios-arm64-simulator/Headers" "${PODS_TARGET_SRCROOT}/Vendor/libgit2.xcframework/ios-arm64/Headers" "${PODS_TARGET_SRCROOT}/Vendor/libgit2.xcframework/ios-arm64-simulator/Headers" "${PODS_TARGET_SRCROOT}/Vendor/libssh2.xcframework/ios-arm64/Headers" "${PODS_TARGET_SRCROOT}/Vendor/libssh2.xcframework/ios-arm64-simulator/Headers"',
    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]' => '"${PODS_TARGET_SRCROOT}/Vendor/libgit2.xcframework/ios-arm64" "${PODS_TARGET_SRCROOT}/Vendor/libssh2.xcframework/ios-arm64" "${PODS_TARGET_SRCROOT}/Vendor/libcrypto.xcframework/ios-arm64" "${PODS_TARGET_SRCROOT}/Vendor/rish_ffi.xcframework/ios-arm64" "${PODS_TARGET_SRCROOT}/Vendor/rish_agent_core.xcframework/ios-arm64"',
    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]' => '"${PODS_TARGET_SRCROOT}/Vendor/libgit2.xcframework/ios-arm64-simulator" "${PODS_TARGET_SRCROOT}/Vendor/libssh2.xcframework/ios-arm64-simulator" "${PODS_TARGET_SRCROOT}/Vendor/libcrypto.xcframework/ios-arm64-simulator" "${PODS_TARGET_SRCROOT}/Vendor/rish_ffi.xcframework/ios-arm64-simulator" "${PODS_TARGET_SRCROOT}/Vendor/rish_agent_core.xcframework/ios-arm64-simulator"',
    'GCC_PREPROCESSOR_DEFINITIONS' => "$(inherited) DSH_LOCAL_PROOF=1 RISH_GUEST_CGI_ENABLED=#{guest_cgi_enabled}",
  }
  spec.frameworks = [
    'WebKit',
    'SafariServices',
    'CoreFoundation',
    'Foundation',
    'ImageIO',
    'PDFKit',
    'Photos',
    'PhotosUI',
    'QuickLook',
    'Security',
    'UIKit',
    'UniformTypeIdentifiers',
  ]
  spec.libraries = ['c++', 'z']
  spec.dependency 'React-Core'
end
