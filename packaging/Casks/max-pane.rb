# Homebrew cask for Max Pane. Lives here so it is versioned with the app.
#
# This file is the template. scripts/release.sh never touches it: it fills
# `version` and `sha256` from the DMG it just built and writes the result to
# dist/max-pane.rb. After a real release the owner copies that file into the tap
# (ddrscott/homebrew-tap) and back over this one, so the committed hash is the
# hash of the asset that actually shipped. Until then the sha256 below is a
# placeholder, deliberately: every DMG build hashes differently, and a real-
# looking hash of an unshipped build is a lie `brew install` would catch late.
cask "max-pane" do
  version "0.6.1"
  sha256 "80011194ce15e4cdf390bd82adb7604827e9155d4149fffba4c2966309207f9d"

  url "https://github.com/ddrscott/max-pane/releases/download/v#{version}/MaxPane-#{version}.dmg"
  name "Max Pane"
  desc "Terminals and web pages as columns, one per coding agent session"
  homepage "https://github.com/ddrscott/max-pane"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Info.plist says LSMinimumSystemVersion 14.0. A bare symbol means "this or
  # newer"; the older `">= :sonoma"` string form is deprecated.
  depends_on macos: :sonoma
  # The build is arm64 only (`lipo -info` on the binary says so); a universal
  # build is a separate decision. Without this, an Intel Mac installs a bundle
  # that will not launch.
  depends_on arch: :arm64
  # The daemon that owns the terminal sessions. Without it the first ⌘O is an
  # error naming an installer; with it, `brew install` gives a working app.
  depends_on formula: "ddrscott/tap/relay-tty"

  app "MaxPane.app"
  # The CLI that lists lanes and opens URLs in them; the app sets it up in the
  # panes it starts, this puts it on the PATH of every other terminal too.
  binary "#{appdir}/MaxPane.app/Contents/Helpers/maxpane"

  zap trash: [
    "~/Library/Application Support/MaxPane",
    "~/.config/maxpane",
    "~/Library/Preferences/app.ljs.maxpane.plist",
    "~/Library/Saved Application State/app.ljs.maxpane.savedState",
  ]

  caveats <<~EOS
    Max Pane runs agent sessions through relay-tty, installed alongside it as
    ddrscott/tap/relay-tty. Press ⌘O in the app, type a command, press ↩.
  EOS
end
