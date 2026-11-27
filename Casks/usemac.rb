cask "usemac" do
  version "0.11.0"
  sha256 "b7dd3b406c0e5362796046d511b56bf38a7d1692bf37408aa9e3c3f25bbcd84a"

  url "https://usemac.app/downloads/usemac-#{version}-arm64.dmg"
  name "UseMac"
  desc "Native macOS GUI and Chrome background automation for AI agents"
  homepage "https://usemac.app"

  livecheck do
    url "https://usemac.app/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "UseMac.app"
  binary "#{appdir}/UseMac.app/Contents/Helpers/usemac"

  zap trash: [
    "~/Library/Application Support/UseMac",
    "~/Library/Caches/app.usemac",
    "~/Library/HTTPStorages/app.usemac",
    "~/Library/Preferences/app.usemac.plist",
  ]
end
