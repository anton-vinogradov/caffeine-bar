# caffeine-bar

A menu bar switch for `caffeinate` on macOS that also shows every other
`caffeinate` keeping your Mac awake, like the ones your scripts and AI agents
start in the background.

[По-русски](README.ru.md)

| Icon | Meaning |
| --- | --- |
| <img src="docs/on.png" width="32" alt="full cup with steam"> | On here |
| <img src="docs/others.png" width="32" alt="outlined cup with steam"> | Off here, but other `caffeinate` processes keep the Mac awake |
| <img src="docs/off.png" width="32" alt="empty cup"> | No `caffeinate` is running |

## Why

Scripts and AI agents often run `caffeinate -dimsu -t 7200 &` so that the Mac
does not sleep in the middle of a long job. Other menu bar tools do not handle
these processes well:

- KeepingYouAwake, Amphetamine, Caffeine and similar apps show only their own
  state. Their icon says "off" while five background `caffeinate` processes
  keep the Mac awake.
- The Raycast Coffee extension does the opposite. It treats any `caffeinate`
  as its own, and both "on" and "off" run `killall caffeinate`. This also
  stops the ones your agents started.

caffeine-bar reads the same data as `pmset -g assertions` every 2 seconds and
shows all of it. It stops only the processes you ask it to stop.

## Use

- **Click** the icon to turn it on or off. "On" has no time limit.
- **Right-click** (or Control-click, or Option-click) to open the menu:
  - **Keep awake for…**: from 30 minutes to 8 hours.
  - **Display may sleep**: keep the system awake, but let the screen turn off.
  - **caffeinate now**: every `caffeinate` process with its flags and the time
    left. Yours is marked "mine". You can stop one of them or all of them.
  - **Also blocking idle sleep**: other apps that keep the Mac awake right
    now, for example the Claude desktop app.
  - **Start at login**.
- **Hover** over the icon to see a short summary.

The menu is in Russian on a Russian system and in English on any other.

## How it works

"On" runs `/usr/bin/caffeinate -dims -w <app pid>` (`-ims` when the display may
sleep), plus `-t <seconds>` for a timer. Because of `-w`, `caffeinate` exits
together with the app, even after a crash or `kill -9`.

The list comes from `IOPMCopyAssertionsByProcess`, the same data that
`pmset -g assertions` prints. A process keeps the Mac awake if it blocks idle
sleep of the system or of the display. `caffeinate -s` counts only on power,
because macOS ignores it on battery.

## Limits

These come from macOS, not from this app:

- It blocks **idle** sleep only. If you close the lid of a MacBook, it still
  goes to sleep. The exception is clamshell mode: power plus an external
  display.
- Timers stop while the Mac sleeps, the same as `caffeinate -t`. A 2-hour
  timer means 2 hours of awake time.
- When the menu bar is full, macOS hides new icons behind the notch. Hold ⌘
  and drag icons to make room, or hide some in System Settings → Menu Bar.
  If you open the app again from Spotlight or Finder, it shows a small window
  with the state and an on/off button.

## Install

You need macOS 15 or later. The app runs on Apple Silicon and Intel Macs.

### Download

1. Download `CaffeineBar-<version>.zip` from the
   [latest release](https://github.com/anton-vinogradov/caffeine-bar/releases/latest)
   and unzip it.
2. Move `CaffeineBar.app` to `~/Applications` or `/Applications`.
3. The app is signed ad hoc, not by an Apple developer ID, so macOS blocks
   the first start. Remove the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine ~/Applications/CaffeineBar.app
   ```

   Or try to open the app, then go to System Settings → Privacy & Security and
   click **Open Anyway**.

### Build from source

You also need the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/anton-vinogradov/caffeine-bar.git
cd caffeine-bar
./build.sh install
```

`build.sh` compiles `main.swift` with `swiftc` for both Apple Silicon and Intel,
signs the app ad hoc, copies it to `~/Applications` and starts it. A local
build has no quarantine flag, so Gatekeeper lets it run. Without `install`, the
script only builds `build/CaffeineBar.app`. `./build.sh zip` also packs it into
a zip for a release.

To start the app at login, open the menu and choose **Start at login**.

## Tip for scripts and agents

Give `caffeinate` the pid of a process that lives as long as the job. Then
`caffeinate` exits when the job ends and does not wait for the whole `-t`:

```bash
caffeinate -dimsu -t 7200 -w $PPID &
```

`$PPID` is the process that started the current shell. For the shell tool of an
AI agent, this is usually the agent itself.

## License

[MIT](LICENSE)
