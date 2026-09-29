class OpenclawFacetime < Formula
  desc "Out-of-process FaceTime audio capture for OpenClaw"
  homepage "https://github.com/openclaw/openclaw-facetime"
  url "https://github.com/openclaw/openclaw-facetime/releases/download/v0.1.1/openclaw-facetime-macos-arm64.zip"
  sha256 "RELEASE_SHA256"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sonoma
  depends_on "sox"

  skip_clean "libexec/facetime-audio-capture"

  def install
    odie "openclaw-facetime requires macOS 14.4 or later" if MacOS.version < "14.4"
    libexec.install "facetime-audio-capture"
    libexec.install "VERSION"
    libexec.install "LICENSE"
    libexec.install "THIRD_PARTY_NOTICES.md"
  end

  def caveats
    <<~EOS
      This formula installs out-of-process audio capture consumed by the OpenClaw FaceTime
      plugin and SoX for the host-owned playback process. It does not install or
      enable the plugin itself.

      Install and configure the plugin separately:
        https://docs.openclaw.ai/plugins/facetime

      No SIP or Developer Tools changes are required. The separately built
      GPL-derived audio driver is intentionally not included in this formula.
    EOS
  end

  test do
    assert_predicate libexec/"facetime-audio-capture", :executable?
    assert_match version.to_s, (libexec/"VERSION").read
    %w[facetime-audio-capture].each do |artifact|
      path = libexec/artifact
      system "/usr/bin/codesign", "--verify", "--strict", path
      signature = shell_output("/usr/bin/codesign -dvv #{path} 2>&1")
      assert_match "Authority=Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)", signature
      assert_match "TeamIdentifier=FWJYW4S8P8", signature
    end
  end
end
