cask "eq-for-mac" do
  version "1.0.0"
  sha256 "24701854a7e846a9d94d27279c343cfc573e58324ebe26580a15b40deb5e9d91"

  url "https://github.com/RavitejaKarra24/eq-for-mac/releases/download/v#{version}/EQ-for-Mac.dmg",
      verified: "github.com/RavitejaKarra24/eq-for-mac/"
  name "EQ for Mac"
  desc "Menu-bar system-wide equalizer using Core Audio Taps"
  homepage "https://github.com/RavitejaKarra24/eq-for-mac"

  depends_on macos: ">= :sonoma"

  app "EQ for Mac.app"

  caveats <<~EOS
    EQ for Mac requires macOS 14.2 or newer.
    This free build is ad-hoc signed and is not notarized by Apple.
    If macOS blocks the first launch, follow the per-app Open Anyway guide:
      https://eq-for-mac.warriors-8531.chatgpt.site/install

    On first use, allow Screen & System Audio Recording in System Settings.
  EOS
end
