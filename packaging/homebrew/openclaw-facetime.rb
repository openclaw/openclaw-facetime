class OpenclawFacetime < Formula
  desc "Native FaceTime audio and call-control helpers for OpenClaw"
  homepage "https://github.com/openclaw/openclaw-facetime"
  url "https://github.com/openclaw/openclaw-facetime/releases/download/v0.1.0/openclaw-facetime-macos-arm64.zip"
  sha256 "RELEASE_SHA256"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    odie "openclaw-facetime requires macOS 14.4 or later" if MacOS.version < "14.4"
    libexec.install "facetime-audio-capture"
    libexec.install "FaceTimeHelper.dylib"
    libexec.install "FaceTimeHelper.build-id"
    libexec.install "VERSION"
    libexec.install "LICENSE"
    libexec.install "THIRD_PARTY_NOTICES.md"
  end

  def caveats
    <<~EOS
      This formula installs native helpers consumed by the OpenClaw FaceTime
      plugin. It does not install or enable the plugin itself.

      Install the plugin separately, then run:
        openclaw plugins enable facetime
        openclaw gateway call facetime.setup --json

      Call control requires SIP debugging restrictions disabled and Developer
      Tools access enabled. The separately built GPL-derived audio driver is
      intentionally not included in this formula.
    EOS
  end

  test do
    assert_predicate libexec/"facetime-audio-capture", :executable?
    assert_predicate libexec/"FaceTimeHelper.dylib", :exist?
    assert_match(/\A[0-9a-f]{64}\n?\z/, (libexec/"FaceTimeHelper.build-id").read)
    assert_match version.to_s, (libexec/"VERSION").read
    system "codesign", "--verify", "--strict", libexec/"facetime-audio-capture"
    system "codesign", "--verify", "--strict", libexec/"FaceTimeHelper.dylib"
  end
end
