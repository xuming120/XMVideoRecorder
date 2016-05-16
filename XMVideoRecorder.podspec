Pod::Spec.new do |s|
  s.name         = "XMVideoRecorder"
  s.version      = "0.0.1"
  s.summary      = "iOS camera engine,real-time processing CVPixelBuffer from camera,preview and generate video."
  s.homepage     = "https://github.com/xuming120/XMVideoRecorder"
  s.license      = "MIT"
  s.author       = { "徐铭" => "xuming120@163.com" }
  s.platform     = :ios, "7.0"
  s.source       = { :git => "https://github.com/xuming120/XMVideoRecorder.git", :tag => "0.0.1" }
  s.source_files = "Source"
  s.frameworks 	 = "Foundation", "AVFoundation", "CoreGraphics", "CoreMedia", "CoreVideo","CoreImage", "ImageIO", "MobileCoreServices", "QuartzCore", "OpenGLES", "UIKit"
  s.requires_arc = true
end
