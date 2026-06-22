cask "glowkey" do
  version "VERSION"
  sha256 "SHA256"

  url "https://github.com/YOUR_GITHUB_USERNAME/glowkey/releases/download/v#{version}/GlowKey-v#{version}-macos.zip"
  name "GlowKey"
  desc "Zero-config macOS external display brightness utility"
  homepage "https://github.com/YOUR_GITHUB_USERNAME/glowkey"

  app "GlowKey-v#{version}/GlowKey.app"

  uninstall launchctl: [
              "fyi.glowkey.daemon",
            ],
            quit: [
              "fyi.glowkey.app",
            ],
            delete: [
              "~/bin/glowkey",
              "~/bin/lumensync",
            ]

  zap trash: [
    "~/Library/Application Support/GlowKey",
    "~/Library/LaunchAgents/fyi.glowkey.daemon.plist",
  ]
end
