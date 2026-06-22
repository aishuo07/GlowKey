class Glowkey < Formula
  desc "Zero-config macOS external display brightness utility"
  homepage "https://github.com/YOUR_GITHUB_USERNAME/glowkey"
  url "https://github.com/YOUR_GITHUB_USERNAME/glowkey/archive/refs/tags/vVERSION.tar.gz"
  sha256 "SHA256"
  license "MIT"

  depends_on xcode: ["14.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"

    bin.install ".build/release/glowkey"
    bin.install ".build/release/glowkey-shade"
    bin.install ".build/release/glowkey-hotkeys"
    bin.install ".build/release/glowkey-daemon"
    bin.install ".build/release/glowkey-menubar"
  end

  test do
    assert_match "GlowKey", shell_output("#{bin}/glowkey help")
  end
end
