# Trading Journal — put it online (free) & install on iPhone/iPad

This folder is a ready-to-host version of your dashboard. Hosting it on **GitHub Pages** is free,
gives you a permanent link, lets you "Add to Home Screen" on iPhone/iPad like a real app, and
updates the market data automatically in the cloud (your PC doesn't need to be on).

## What's in here
- `index.html` — the dashboard (same as on your Desktop, + app/PWA support)
- `manifest.webmanifest`, `sw.js`, `icon-*.png`, `apple-touch-icon.png` — make it installable & offline
- `update-market-data.ps1` — the data fetcher
- `market-cache.js` — last market snapshot (auto-refreshed by the workflow below)
- `.github/workflows/market.yml` — GitHub runs this daily to refresh `market-cache.js`

## One-time setup (about 5 minutes)
1. Create a free account at **https://github.com** (you may already have one).
2. Click **New repository**. Name it e.g. `trading-journal`. Set it **Public**. Click **Create**.
3. On the repo page: **Add file → Upload files**. Drag in **everything in this folder**
   (including the `.github` folder — keep the folder structure). Click **Commit changes**.
4. Go to **Settings → Pages**. Under "Build and deployment", Source = **Deploy from a branch**,
   Branch = **main**, Folder = **/(root)**, click **Save**. Wait ~1 minute.
5. Your link appears at the top of the Pages settings, like:
   `https://YOURNAME.github.io/trading-journal/`

## Install on iPhone / iPad
1. Open that link in **Safari**.
2. Tap the **Share** button → **Add to Home Screen** → **Add**.
3. It now has the TJ icon and opens full-screen like an app. (Do the same on your PC browser if you like.)

## Daily market data (automatic, no PC needed)
- The workflow refreshes `market-cache.js` every day. To run it now: repo **Actions** tab →
  **Update market data** → **Run workflow**. (First time, click the green button to enable Actions.)

## Important — about your trades
Your journal entries are saved **in each device's browser** (private to that device). They are **not**
in this repo and not visible to anyone with the link. To move trades between devices, use the
**Backup** button (download a `.json`) and **Restore** it on the other device — e.g. via iCloud Drive.

> Want trades to sync automatically across PC + iPhone + iPad (one shared journal, passcode-protected)?
> That's the next step — ask and I'll add free cloud sync.

## Updating the dashboard later
If the dashboard changes, re-upload the new `index.html` (and bump `tj-cache-v1` in `sw.js` to
`tj-cache-v2` so phones pick up the new version).
