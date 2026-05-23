# Design: ship v0.1.4 + switch distribution to a Homebrew cask

Date: 2026-05-22
Status: approved (pending spec review)

## Background

Two things ship together:

1. **A grabber bug fix (already implemented and tested in this branch).** The
   `skhd-grabber` daemon seizes the physical keyboard and replays keystrokes
   through Karabiner's virtual HID device (`vhidd`). When the `vhidd` transport
   died, the grabber kept the keyboard seized while every replay was dropped — a
   dead keyboard. Two changes fix it:
   - `src/grabber/Vhidd.zig`: `isTransportError` was an over-narrow allowlist
     (`SendFailed`/`ShortWrite` only). It now treats *any* post error as
     transport-fatal except our-side logic bugs (`PayloadTooLarge`,
     `TooManyKeys`), so `ConnectionResetByPeer` / `BrokenPipe` / `Unexpected`
     trigger recovery instead of being ignored.
   - `src/grabber/main.zig`: `applyLatestRules` now tears down the seize
     *before* the (blocking, up-to-5s) `vhidd` connect, so the physical keyboard
     is never seized while we wait on `vhidd`.

   Verified locally: agent `0.1.4-dev` + grabber running from
   `/Applications/skhd.app`, keyboard responsive, no regression.

2. **A distribution change.** Today `skhd.zig` is distributed as a Homebrew
   **formula** (`jackielii/homebrew-tap` → `Formula/skhd-zig.rb`) that downloads
   a pre-built `skhd.app` tarball, installs it into the Cellar, and asks users to
   manually `ln -sfn` the bundle into `/Applications`. Since the release artifact
   is already an `.app` bundle, a **cask** is the natural fit: it installs to
   `/Applications` automatically.

## Constraint: no Apple Developer ID

There is no Developer ID and no notarization. Releases are signed with a
self-signed `skhd-cert` (stored as a CI secret; `TeamIdentifier=not set`).

Implication for a cask: cask-downloaded apps receive the `com.apple.quarantine`
attribute and Gatekeeper would block an un-notarized app. The accepted
workaround for an unsigned cask in a personal tap is a `postflight` that strips
the quarantine bit. Net behavior then equals today's formula: the app runs, and
TCC grants (Accessibility / Input Monitoring) remain **manual one-time grants**
keyed to the self-signed cert. This is unchanged from the status quo — the cask
only adds the `/Applications` placement.

## Decisions

- **Cask token: `skhd-zig`** (unchanged from the formula token).
  - The command users type is `skhd` regardless of token, because a `binary`
    stanza symlinks `skhd.app/Contents/MacOS/skhd` onto `PATH`. The token only
    matters at install time.
  - Keeping `skhd-zig` means new users run the **same** command they always
    have: `brew install skhd-zig`. With no formula by that name but a cask by
    that name, Homebrew falls back automatically ("No available formula …; found
    a cask named 'skhd-zig' instead") and installs the cask — no `--cask` flag
    required.
  - `skhd-zig` has zero collision with the original C `skhd`
    (`koekeishiya/formulae/skhd`), which was the only naming risk considered.
- **Replace the formula entirely** — delete `Formula/skhd-zig.rb`, add
  `Casks/skhd-zig.rb`.
- **arm64-only**, matching the formula's paused-Intel stance. The release still
  produces an x86_64 tarball, but the cask ignores it.
- **Grabber + Karabiner dext install stays a runtime `sudo skhd --install-grabber`
  step in caveats** — not bundled as a cask `pkg`. Same as today.
- **Land the fix via branch → PR → merge to `main`**, then tag `v0.1.4` from
  `main` (consistent with the repo's PR history, e.g. #40/#41, and runs CI).

## The cask: `homebrew-tap/Casks/skhd-zig.rb`

Representative structure (exact `macos:` minimum and `zap`/`uninstall` paths
finalized during implementation):

```ruby
cask "skhd-zig" do
  version "0.1.4"
  sha256 "<arm64 tarball sha256>"

  url "https://github.com/jackielii/skhd.zig/releases/download/v#{version}/skhd-arm64-macos.tar.gz"
  name "skhd.zig"
  desc "Simple hotkey daemon for macOS, written in Zig"
  homepage "https://github.com/jackielii/skhd.zig"

  depends_on arch: :arm64
  depends_on macos: ">= :big_sur"

  app "skhd.app"
  binary "#{appdir}/skhd.app/Contents/MacOS/skhd"

  # No Developer ID / notarization: strip the download quarantine so the
  # self-signed bundle runs (TCC grants remain manual, same as the formula).
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/skhd.app"]
  end

  uninstall launchctl: "com.jackielii.skhd",
            quit:      "com.jackielii.skhd"

  caveats <<~EOS
    Configuration:
      touch ~/.config/skhd/skhdrc

    Setup (idempotent):
      skhd --start-service
      # Prompts for Accessibility + Input Monitoring on first launch. If your
      # config uses .remap / .taphold / fn_layer rules, also prompts (sudo) to
      # install skhd-grabber + the Karabiner-DriverKit-VirtualHIDDevice .pkg.
      skhd --status

    Full teardown of the root grabber (cask uninstall can't sudo):
      sudo skhd --uninstall-grabber

    Logs:
      ~/Library/Logs/skhd.log    (agent)
      /var/log/skhd-grabber.log  (grabber, if installed)
  EOS

  zap trash: [
    "~/Library/Logs/skhd.log",
  ]
end
```

Open implementation detail: the root `skhd-grabber` LaunchDaemon can't be torn
down by `brew uninstall --cask` without a sudo prompt, so full grabber removal
stays a documented `sudo skhd --uninstall-grabber` step in caveats rather than
an `uninstall script:` directive.

## Release automation: `skhd.zig/.github/workflows/release.yml`

The `update-homebrew` job currently `sed`s `Formula/skhd-zig.rb` for version,
url, and both arm64 + x86_64 sha256. Change it to:

- `git add` / `sed` target → `Casks/skhd-zig.rb`.
- Keep the version + url + **arm64** sha256 substitutions (the cask's `version`,
  `url`, and `sha256` lines).
- Drop the x86_64 url + sha256 substitutions (cask is arm64-only).
- Commit message and asset download logic unchanged.

The job's pre-release skip (`-alpha`/`-beta`/`-rc`) and tap checkout are
unchanged.

## Execution sequence

Ordering matters: the auto-bump job only edits an **existing** file, so the cask
must exist in the tap before the v0.1.4 release runs.

1. **`skhd.zig`**: branch → PR with the grabber fix + the `release.yml`
   `update-homebrew` change → merge to `main`.
2. **`homebrew-tap`**: add `Casks/skhd-zig.rb` (correct structure so the `sed`
   patterns match; initial version/sha can be the v0.1.3 values — the release
   job overwrites them), delete `Formula/skhd-zig.rb`, commit, push.
3. **`skhd.zig`**: tag `v0.1.4` on `main`, push the tag → `release.yml` builds,
   self-signs, publishes the GitHub release, then the `update-homebrew` job
   `sed`s `Casks/skhd-zig.rb` to v0.1.4 + the real arm64 sha256 and pushes.
4. **Verify** on this machine:
   `brew untap jackielii/tap; brew install --cask jackielii/tap/skhd-zig`
   (or `brew install jackielii/tap/skhd-zig` to confirm the formula→cask
   fallback), then `skhd --start-service` + `skhd --status`.

Note: pushing the `v0.1.4` tag is an outward-facing, hard-to-reverse action
(publishes a public release). Confirm before pushing.

## Migration for existing users

Document in the v0.1.4 release notes:

```
brew uninstall skhd-zig        # removes the old formula
brew install skhd-zig          # installs the cask (auto-fallback) → /Applications/skhd.app
```

`brew upgrade` will NOT auto-convert an installed formula into a cask, so the
uninstall + reinstall is required once.

## Non-goals (YAGNI)

- No Developer ID certificate or notarization.
- No `pkg`-based grabber/dext install inside the cask.
- No Intel/x86_64 cask variant.
- No change to how the grabber/agent themselves work (beyond the bug fix).

## Risks

- **Quarantine strip on newer macOS.** `xattr -dr com.apple.quarantine` in
  `postflight` is the standard unsigned-cask workaround, but Gatekeeper on
  recent macOS is stricter. Mitigation: the app is launched by launchd /
  SMAppService, not Finder double-click, which is the lenient path; verified
  working locally via the equivalent `install-local` overlay.
- **TCC re-grant on the cert change.** Switching from the CI-signed bundle to a
  cask-delivered bundle keyed to the same self-signed `skhd-cert` may require a
  one-time Accessibility / Input Monitoring re-grant — same one-time cost the
  formula already has, documented in caveats.
- **First-cask bootstrap.** If the cask file is missing from the tap when the
  release job runs, the `sed` no-ops/fails silently. Step 2 must precede step 3.
```