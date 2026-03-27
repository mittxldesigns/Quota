# Quota

A tiny macOS menu bar app that shows how much of your Claude rate limit you've used.

I got tired of getting rate-limited mid-conversation with no warning, so I built this. It sits in your menu bar, polls your usage every 60 seconds, and shows you a colored gauge so you know when to slow down.

Works with Claude Pro, Max, and Team accounts. No API key needed — just sign in with your Claude account.

## Install

Download the `.dmg` from [Releases](../../releases), open it, drag to Applications. Done.

Or build it yourself:

```
git clone https://github.com/tanishmittal/Quota.git
cd Quota
bash build.sh          # just builds
bash build.sh --install # builds + copies to /Applications
```

Needs Xcode 26+ and macOS 26.

## What it does

- Shows your 5-hour and 7-day usage as a small arc gauge in the menu bar
- Color goes green → yellow → orange → red as you approach the limit
- Sends you a notification at 50%, 80%, and 95% so you're never caught off guard
- Shows whether you're in peak hours (5-11 AM PT weekdays) where tokens cost more
- Auto-checks for updates from GitHub releases
- Starts at login by default (you can turn it off)

## How it works

Signs in via OAuth (same flow Claude Code uses), then hits the `/api/oauth/usage` endpoint every minute. That endpoint just returns your current utilization — it doesn't use any of your quota.

Credentials are stored in `~/Library/Application Support/Quota/` with 600 permissions. Everything stays on your machine.

## Privacy

No analytics. No telemetry. No tracking. The app talks to two domains: `api.anthropic.com` (usage data) and `platform.claude.com` (auth). That's it. Read the source if you want to verify.

## Building

The whole thing is four Swift files:

- `App.swift` — menu bar entry point, draws the arc gauge
- `MenuBarView.swift` — the popover UI
- `OAuthService.swift` — OAuth PKCE login + token refresh
- `RateLimitService.swift` — polling, parsing, notifications, peak hours

No dependencies. No SPM. No Xcode project. Just `swiftc` and a shell script.

## License

MIT

---

Made by [Tanish Mittal](https://github.com/tanishmittal)
