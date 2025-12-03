platform :ios, '17.0'

target 'ios_realtime_trans' do
  use_frameworks!

  # WebRTC with AEC3
  pod 'WebRTC-SDK', '~> 125.6422.04'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
      # 禁用 User Script Sandboxing 以解決 WebRTC framework 複製問題
      config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
    end
  end

  # 也為主專案設置
  installer.generated_projects.each do |project|
    project.targets.each do |target|
      target.build_configurations.each do |config|
        config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
      end
    end
  end
end
