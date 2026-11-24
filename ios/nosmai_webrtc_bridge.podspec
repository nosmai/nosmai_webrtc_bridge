Pod::Spec.new do |s|
  s.name             = 'nosmai_webrtc_bridge'
  s.version          = '0.1.0'
  s.summary          = 'Publish a Nosmai-processed camera feed over raw WebRTC (flutter_webrtc).'
  s.description      = <<-DESC
Exposes Nosmai's processed CVPixelBuffer output as a flutter_webrtc video track. The host app owns
the RTCPeerConnection, signalling, ICE/TURN and audio.
                       DESC
  s.homepage         = 'https://nosmai.com'
  s.license          = { :type => 'Commercial' }
  s.author           = { 'Nosmai' => 'admin@nosmai.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m}'
  s.public_header_files = 'Classes/NosmaiWebRtcBridgePlugin.h'

  s.dependency 'Flutter'
  # FlutterWebRTCPlugin.h / LocalVideoTrack.h and (transitively) the WebRTC-SDK pod (<WebRTC/*.h>).
  s.dependency 'flutter_webrtc'
  # The host's Nosmai Flutter plugin selects the native SDK version.
  s.dependency 'NosmaiCameraSDK'

  s.platform = :ios, '15.0'
  s.frameworks = 'CoreVideo', 'CoreImage', 'CoreMedia', 'Foundation'
  s.static_framework = true
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '$(inherited) -framework nosmai'
  }
end
