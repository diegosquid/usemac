cask "usemac" do
  version "0.10.0"
  sha256 "74ed67a5a1a486d5f7646560a351ef262512fd642d4e40774b0368bcb31cc70b"

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
