# LiveChar — live AI character changer

Webcam in, character out, in real time. Three engines, switchable in the UI:

| Engine | Via | Output | Price |
|---|---|---|---|
| Decart Lucy (`lucy-latest` = 2.6) | Decart API direct | 720p, + fast mode | Decart rates (fast = 2x) |
| Eden Live 5B | fal.ai | 1280x704 @ 24fps | $0.0035/s |
| Eden Live 14B | fal.ai | 832x480 @ 16fps | $0.01/s |

## Run (EC2 / Ubuntu, Node 20.12+)

    npm install
    cp .env.example .env      # fill FAL_KEY, DECART_API_KEY, APP_PASSWORD
    npm start                 # or: pm2 start server.js --name livechar

`public/app.js` is prebuilt. After editing `src/app.js`: `npm run build`.

Camera access needs HTTPS — put it behind Nginx + Let's Encrypt:

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 12m;
    }

## How each engine takes the character

- **Lucy**: reference image + prompt go straight to the model. "Apply changes live" swaps them mid-session.
- **Eden Live**: renders from a "target look" first frame. With a character image, the server builds that
  frame from your camera frame + the image (`/api/first-frame`, FLUX.2 klein edit), then starts the stream.
  Prompt only = Eden builds its own reference. Changing the image mid-session re-anchors (short reset).

## Files

    server.js          Express: login gate, Decart token, fal proxy, first-frame
    src/app.js         frontend source
    public/            index.html + bundled app.js

Keys never reach the browser: Decart uses 60s client tokens, fal goes through `/api/fal/proxy`
(locked to the two Eden endpoints). `MAX_SESSION_SECONDS` caps each session.

## Windows desktop app (`desktop/`)

Electron shell around the same web app, plus:

- **Virtual camera** — tick "Virtual camera output", then pick **DirectShow Softcam** as the camera in
  the other app. 1280x720, fed from the output pane. Uses [Softcam](https://github.com/tshino/softcam) (MIT).
- **Output zoom** — scroll over the output to zoom (1x–4x), drag to move, double-click to reset.
  The virtual camera gets the same framing. (Zoom also works in the browser version.)

The app loads your LiveChar server, so the server must be running on HTTPS first.

### Build with GitHub Actions

1. Push this folder to a GitHub repo (branch `main`).
2. Optional: repo Settings → Variables → `LIVECHAR_URL` = `https://your-server` to bake the address in.
   Otherwise the app asks for it on first run (changeable from the LiveChar menu).
3. Actions → "Build Windows app" → Run workflow (also runs on pushes touching `desktop/`).
4. Download `LiveChar-Setup-1.0.0.exe` from the run's artifacts. Pushing a `v*` tag attaches it to a release.

The installer needs admin rights once (it registers the camera). It is unsigned, so Windows
SmartScreen will show a warning on first run.
