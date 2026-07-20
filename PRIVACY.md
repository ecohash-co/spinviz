# SpinViz Privacy Policy

**Effective date:** July 20, 2026
**Publisher:** Team Ecohash

SpinViz (the Apple TV and Android TV music-visualizer app) is built to work
entirely within your own home. This policy describes what the app does — and
mostly, what it does not do.

## The short version

**SpinViz collects no data.** No analytics, no advertising, no tracking, no
accounts, and nothing is ever transmitted to Team Ecohash or any third party.

## What the app actually does with data

- **Connects only to servers you configure.** SpinViz talks to your own
  [Music Assistant](https://music-assistant.io) server on your local network
  (discovered via mDNS or an address you enter), and — optionally — to your own
  Home Assistant server if you enable speaker-group features. All audio,
  artwork, and music metadata flow directly between your devices and your
  servers. None of it reaches us.
- **Stores settings on your device.** Preferences (visual tuning, favorites,
  your chosen player name, server addresses, and an optional Home Assistant
  access token you provide) are stored locally on the device. On Android these
  settings may be included in your own Google device backup; on Apple TV the
  app's identifier is stored in the device keychain. These stores belong to
  you, not us.
- **Uses one app-generated identifier.** The app creates a random identifier on
  first launch so *your* Music Assistant server can recognize the device as the
  same player over time. It is not derived from hardware identifiers, is never
  sent to Team Ecohash or any third party, and never leaves your network.

## What the app does not do

- No collection of personal information, usage data, or diagnostics.
- No advertising or ad identifiers.
- No third-party analytics or tracking SDKs.
- No account creation or sign-in.
- No sale or sharing of data (there is nothing to sell or share).

## Children

SpinViz is a general-audience utility and does not knowingly collect any
information from anyone, including children.

## Changes

If this policy ever changes (for example, if an opt-in crash-reporting feature
were added), the change will be published at this URL with a new effective
date before it takes effect.

## Contact

Questions about this policy: open an issue on this repository
([github.com/ecohash-co/spinviz/issues](https://github.com/ecohash-co/spinviz/issues))
or contact Team Ecohash via the support address listed on the app's store page.
