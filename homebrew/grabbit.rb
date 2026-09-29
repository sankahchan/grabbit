cask "grabbit" do
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/sankahchan/grabbit/releases/download/v#{version}/Grabbit-v#{version}.dmg"
  name "Grabbit"
  desc "Open-source IDM-class download manager for macOS"
  homepage "https://github.com/sankahchan/grabbit"

  auto_updates true

  app "Grabbit.app"

  zap trash: [
    "~/Library/Application Support/Grabbit",
    "~/Library/Preferences/com.sankahchan.grabbit.plist",
    "~/Library/Caches/com.sankahchan.grabbit",
  ]
end
