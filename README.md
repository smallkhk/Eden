# LiveChar — live AI character changer

Webcam in, character out, in real time. Three engines, switchable in the UI:

| Engine | Via | Output | Price |
|---|---|---|---|
| Decart Lucy (`lucy-latest` = 2.6) | Decart API direct | 720p, + fast mode | Decart rates (fast = 2x) |
| Eden Live 5B | fal.ai | 1280x704 @ 24fps | $0.0035/s |
| Eden Live 14B | fal.ai | 832x480 @ 16fps | $0.01/s |

## Run (Ubuntu VPS, Node 22.13+)

    npm install --omit=dev
    PORT=3210 pm2 start server.js --name livechar

Open the site and **register straight away: the first account becomes the admin.**
Then go to **Admin** (top right) and paste the fal.ai and Decart keys. No keys go in `.env`.

`public/app.js` is prebuilt. After editing `src/app.js`: `npm install && npm run build`.

Camera access needs HTTPS — put it behind Nginx + Let's Encrypt (`client_max_body_size 12m`).

## Accounts, balance and admin

- Anyone can create an account (switch sign-ups off in Admin). New accounts start at 0 unless you set free sign-up seconds.
- Balance is in **seconds**. A live session takes `rate` balance-seconds per second of video; rates are per engine (default 1).
- Billing starts when the output video appears (connecting is free for up to 20s, so a failed connection costs nothing),
  is charged every 5s, and stops on Stop, when the balance hits 0, or at the max session length.
- Admin: API keys, rates, limits, USDT addresses, packages, voucher codes, orders, preset characters, email settings,
  users (add/remove seconds, reset password, disable, make admin), sessions and balance history.
- Data lives in `data/` (SQLite database + saved character images). Back that folder up.

### Top-ups

- **USDT (BEP-20 / TRC-20):** add your receiving addresses and at least one package in Admin. A buyer picks a package,
  gets an exact amount to send (the last digits are unique to their order), pays, and pastes the transaction ID.
  The server checks it on-chain through public endpoints and adds the seconds. It keeps checking in the background.
  If someone sends the wrong amount, the order stays unpaid: check your wallet, then press Approve on the order.
- **Voucher codes:** generate codes worth a number of seconds in Admin; users redeem them on their Account page.

### Password reset by email

Fill in the SMTP settings in Admin (and the Site URL). Users can add an email on sign-up or on their Account page.
Without SMTP, reset passwords from the Users table in Admin.

Limits to know: the video runs browser-to-provider, so the server meters by clock and heartbeat. Lucy sessions are
hard-capped by Decart to the seconds the user can pay for. Eden sessions are capped by the app only.

## How each engine takes the character

- **Lucy**: reference image + prompt go straight to the model. "Apply changes live" swaps them mid-session.
- **Eden Live**: renders from a "target look" first frame. With a character image, the server builds that
  frame from your camera frame + the image (`/api/first-frame`, FLUX.2 klein edit), then starts the stream.
  Prompt only = Eden builds its own reference. Changing the image mid-session re-anchors (short reset).

## Files

    server.js          Express: accounts, billing, admin API, Decart token, fal proxy, first-frame
    public/admin.html  admin panel
    src/app.js         frontend source
    public/            index.html + bundled app.js, account.html, reset.html
    lib/chain.js       USDT payment checks (BSC + Tron)

Keys never reach the browser: Decart uses 60s client tokens, fal goes through `/api/fal/proxy`
(locked to the two Eden endpoints, and only during a paid session).

## Windows desktop app (`desktop/`)

Electron shell around the same web app, plus:

- **Virtual camera** — tick "Send to virtual camera", then pick the camera in the other app:
  - **LiveChar Camera** — Windows 11 only, visible to every app (Media Foundation). Source in `desktop/wincam`,
    based on [VCamSample](https://github.com/smourier/VCamSample) (MIT). Always 1280x720.
  - **DirectShow Softcam** — Windows 10 and 11, visible to classic desktop apps and browsers.
    Uses [Softcam](https://github.com/tshino/softcam) (MIT).
- **Output zoom** — scroll over the output to zoom (1x–4x), drag to move, double-click to reset.
  The virtual camera gets the same framing. (Zoom also works in the browser version.)

- **Hotkeys** (work while another app is in front): Ctrl+Alt+S start/stop, Ctrl+Alt+Up/Down zoom, Ctrl+Alt+0 reset zoom,
  Ctrl+Alt+V virtual camera, Ctrl+Alt+P photo, Ctrl+Alt+R record.
- **Tray** — minimizing sends the app to the tray and keeps the video and virtual camera running. Closing the window quits.
- **Auto-update** — installed apps update from the latest GitHub release. To ship one: Actions → Build Windows app →
  Run workflow → set "release version" (e.g. `1.2.0`). Use a higher number each time.

The app loads your LiveChar server, so the server must be running on HTTPS first.

### Build with GitHub Actions

1. Push this folder to a GitHub repo (branch `main`).
2. Optional: repo Settings → Variables → `LIVECHAR_URL` = `https://your-server` to bake the address in.
   Otherwise the app asks for it on first run (changeable from the LiveChar menu).
3. Actions → "Build Windows app" → Run workflow (also runs on pushes touching `desktop/`).
4. Download `LiveChar-Setup-1.0.0.exe` from the run's artifacts. Pushing a `v*` tag attaches it to a release.

The installer needs admin rights once (it registers the camera). It is unsigned, so Windows
SmartScreen will show a warning on first run.

## iOS app (`ios/`)

Native Swift shell (WKWebView) around the same web app, iPhone and iPad, iOS 15+.

- Camera works only for your LiveChar server; links to other sites open in Safari.
- **Photo / Record** save straight to Photos (falls back to the share sheet).
- **Pinch** the output to zoom, drag to move, double-tap to reset (also works in mobile browsers).
- Screen stays awake while the app is open. **Shake** the phone for Reload / Change server.
- No virtual camera on iOS: Apple does not let apps create one.

### Build with GitHub Actions

Actions → "Build iOS app" → Run workflow (also runs on pushes touching `ios/`). Download `LiveChar-iOS`
from the run's artifacts: it holds `LiveChar.ipa`, unsigned. Install it with SideStore, AltStore, Sideloadly or esign
(they sign it with your Apple ID). Set "release version" to also attach the .ipa to release `v<version>`.

The server address comes from the `LIVECHAR_URL` repo variable, else the one in `ios/project.yml`.
