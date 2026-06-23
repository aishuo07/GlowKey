cask "glowkey" do
  version "VERSION"
  sha256 "SHA256"

  url "https://github.com/YOUR_GITHUB_USERNAME/GlowKey/releases/download/v#{version}/GlowKey-v#{version}-macos.zip"
  name "GlowKey"
  desc "Zero-config macOS external display brightness utility"
  homepage "https://github.com/YOUR_GITHUB_USERNAME/GlowKey"

  app "GlowKey-v#{version}/GlowKey.app"

  postflight do
    system_command "/bin/sh",
                   args: [
                     "-c",
                     "find \"#{appdir}/GlowKey.app\" -exec xattr -d com.apple.quarantine {} \\; 2>/dev/null || true",
                   ]
  end

  caveats <<~EOS
    GlowKey is currently unsigned and not notarized. This cask clears Homebrew
    quarantine after install to avoid macOS showing a misleading "damaged" warning.

    If macOS still blocks launch, run:

      find /Applications/GlowKey.app -exec xattr -d com.apple.quarantine {} \\; 2>/dev/null || true
  EOS

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
