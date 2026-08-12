<p align="center">
  <img src="docs/images/perch-logo.png" alt="" width="128">
</p>

<h1 align="center">Perch</h1>

<p align="center">
  <strong>A little screen that perches on your desk</strong> — what your coding agents are
  doing, without giving up a window for it.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/ESP--IDF-v5.5-E7352C?logo=espressif&logoColor=white" alt="ESP-IDF v5.5">
  <img src="https://img.shields.io/badge/board-ESP32--2432S028R-3C3C3C" alt="ESP32-2432S028R">
  <img src="https://img.shields.io/badge/link-BLE%20%2B%20Wi--Fi-0082FC?logo=bluetooth&logoColor=white" alt="BLE with a Wi-Fi fallback">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3DA639" alt="MIT license"></a>
</p>

<p align="center">
  🌐 <strong>English</strong> · <a href="README.th.md">ไทย</a>
</p>

<p align="center">
  <a href="#what-the-screen-says">What the screen says</a> ·
  <a href="#what-you-need">What you need</a> ·
  <a href="#1-get-the-repository-and-the-swift-compiler">Getting started</a> ·
  <a href="#the-case">The case</a> ·
  <a href="#on-the-go">On the go</a> ·
  <a href="#troubleshooting">Troubleshooting</a>
</p>

<p align="center">
  <img src="docs/images/photo-desk-row.jpg" width="860" alt="Four Perch units side by side on a desk: the clock, two sessions with status cards, the quota screen, and the back cover with its engraved mascots and status LED">
</p>

<p align="center"><sub>Left to right: the clock it becomes after 21:00 · sessions that need
you · quota and machine load · the back, with the status LED and the three species engraved.</sub></p>

> **Before you start**
> - **macOS only.** The app that talks to Claude Code is a Swift menu bar app for macOS 14
>   or newer. There is no Linux or Windows build, and the firmware alone does nothing
>   without it.
> - **Unofficial.** A personal hobby project, not affiliated with or endorsed by Anthropic.
>   "Claude" and "Claude Code" belong to them.
> - **As-is.** Flashing firmware overwrites whatever is on the board, and you do it at your
>   own risk. No warranty — see [LICENSE](LICENSE).
> - Reading your quota from claude.ai is optional and needs an account credential. Read
>   [step 5](#5-quota-on-the-board) before you turn it on.

A desk device that shows what your coding agents are doing right now. Blocky little
creatures live on a small screen next to your keyboard — one per session, a different
species per agent: they type when the agent types, wave when a session needs your answer,
and celebrate when a build finishes. The bars at the bottom are your usage quota, the top
strip is the time and the weather, and after 21:00 the whole thing turns into a clock.

<img src="docs/images/screen_busy.gif" width="420" alt="Three sessions working, cards stacked on the right, quota bars at the bottom"> <img src="docs/images/app-menu.jpg" width="236" alt="The menu bar panel: session usage, weekly usage, and the board's state">

*The board, and the menu bar app that feeds it.*

Nothing leaves your network. A menu bar app on your Mac reads Claude Code's hooks and
pushes a small snapshot to the board over Bluetooth LE — and, if you set up Wi-Fi, over
your own LAN as a sealed fallback when Bluetooth goes quiet. The board never talks to
claude.ai.

## What the screen says

**While a session runs**

| Busy | Waiting for you | Done |
|:--|:--|:--|
| ![busy](docs/images/screen_busy.gif) | ![waiting](docs/images/screen_waiting.gif) | ![done](docs/images/screen_done.gif) |
| Up to three sessions and the tool each one is using. | A session stopped and wants an answer. | The mascot celebrates a finished turn. |

**When nothing is happening**

| Idle | No sessions | Offline |
|:--|:--|:--|
| ![idle](docs/images/screen_idle.gif) | ![empty](docs/images/screen_empty.gif) | ![offline](docs/images/screen_offline.gif) |
| One session, sleeping. Night sky and clock. | The mascot strolls. Clock and date. | The Mac is out of range or the app is not running. |

**Quota**

| Normal | Running hot | Unknown |
|:--|:--|:--|
| ![usage](docs/images/screen_usage.gif) | ![usage hot](docs/images/screen_usage_hot.gif) | ![usage unknown](docs/images/screen_usage_unknown.gif) |
| The current 5-hour window and the weekly one. | Near the limit; the tick marks your pace against the clock. | `--`, never a guess, when no number has arrived. |

**Over Wi-Fi**

| Still live | Nobody feeding it |
|:--|:--|
| ![lan](docs/images/screen_lan.gif) | ![wifi](docs/images/screen_wifi.gif) |
| Bluetooth is gone, so the label is the board's IP and the icon is a wave — but the snapshot still arrives, sealed, over the network. | The board is on the network with nothing to show: the Mac is asleep or the app is not running. |

**At night, and when you touch it**

<img src="docs/images/screen_night.png" width="420" alt="The screen at night: a large seven-segment clock in the mascot's own orange, the date below it, and nothing else">

From 21:00 to 07:00 the screen becomes a clock and nothing else: no mascot, no sky, no grass,
no alerts, and the onboard LED goes dark. Sessions keep running and alerts keep arriving —
they simply wait until morning. This is for a bedroom: a status display that lights up the
room at 3am is a status display you unplug. Touch the screen and it comes back to normal for
15 seconds, then settles again.

The digits are the mascot's own orange rather than white, and not only because it is the
project's colour — a warm colour carries far less blue, which is the part of the spectrum
that disrupts sleep most. Same brightness, different light.

Outside those hours the backlight fades down after a minute of no touching and wakes
instantly when you tap. Tapping also pages to the quota panel.

## Three agents, three species

Perch does not ask which agent you use — it watches for all three and shows whatever it finds.
The silhouettes differ, not just the colours, because from across a room you read a shape long
before you read a colour.

| | Looks like | Found by | Setup |
|:--|:--|:--|:--|
| **Claude Code** | Blocky, four legs, orange | Its hook system | One click in the gear menu |
| **Codex CLI** | A screen on two legs, blue | Reading its rollout files as they are written | **None** |
| **Antigravity** (`agy`) | An arch you can see through, purple | Reading `~/.gemini/antigravity-cli` | **None** |

Codex and Antigravity have no hook system to install into, so Perch reads the files they
already write. Nothing is configured, nothing of theirs is modified, and neither is asked to
report anything — if the tool is on the machine and running, it appears on the screen.

## What you need

**Hardware**

- An **ESP32-2432S028R** board — the "Cheap Yellow Display", 2.8" 320x240, roughly 300 baht.
  Tested against ESP32-D0WD-V3 rev 3.1, 4 MB flash, no PSRAM.
- A **USB data cable** for the board's micro-USB port. Charge-only cables do not enumerate.

<a href="https://s.shopee.co.th/4qEXaCOFvu"><img src="docs/images/button-shop-en.webp" width="320" alt="Buy the ESP32 2.8&quot; board on Shopee"></a>

<sub>That button is a Shopee affiliate link — buying through it costs you nothing extra and
sends a small commission here. Any seller's ESP32-2432S028R works just as well.</sub>

**Mac**

- macOS 14 or newer, with Bluetooth.
- [Claude Code](https://claude.com/claude-code) installed and logged in.

The Mac app is always built from source. The firmware you can either download or build —
step 2 has both routes.

A case is optional — the board works fine bare. If you have a printer or a print shop,
[the case](#the-case) is two parts and needs no supports.

## The case

Two printed parts, no supports, no screws beyond the four that come with the board. The
front is a bezel the board drops into; the back carries the three mascots and lets the
status LED through.

| Part | What it is | |
|---|---|---|
| **[front_case_v4_slot.stl](hardware/case/front_case_v4_slot.stl)** | the bezel — one long slot covers both the USB-C and micro-USB ports | [**⬇ download**](hardware/case/front_case_v4_slot.stl?raw=1) |
| **[back_cover.stl](hardware/case/back_cover.stl)** | the back — mascots engraved on the outside, vents for the LED | [**⬇ download**](hardware/case/back_cover.stl?raw=1) |
| **[PRINT_NOTE.txt](hardware/case/PRINT_NOTE.txt)** | settings that matter, in Thai and worth reading | [**⬇ download**](hardware/case/PRINT_NOTE.txt?raw=1) |

<sub>Click a filename and GitHub renders the STL as a model you can spin before you commit
a print; the download column gives you the file straight away.</sub>

<p align="center">
  <img src="docs/images/photo-four-up.jpg" width="620" alt="Studio view of all four faces: clock, session cards, quota, and the engraved back cover">
</p>

**Two settings decide whether it looks good**, and neither is the one people reach for
first. Print it in **4–5 perimeters with 5–6 solid top layers** — thin walls let the
screen's backlight glow through the plastic at night, and no amount of infill fixes it
(40% is plenty). A darker filament helps for the same reason.

Print the front face-down on the bed and the back engraving-side up. The engraving floor
is a top surface, so give it those solid layers or it comes out furry.

<p align="center">
  <img src="docs/images/photo-desk-angled.jpg" width="420" alt="Three units angled on a desk with the back cover behind them">
  <img src="docs/images/photo-night.jpg" width="420" alt="A single unit on a nightstand at night, showing the clock face">
</p>

<sub>These STLs are what we print and test-fit ourselves. They fit the ESP32-2432S028R
listed above; other boards with the same screen are not guaranteed to match.</sub>

## 1. Get the repository and the Swift compiler

```bash
xcode-select --install
git clone https://github.com/zeuscs09/perch.git
cd perch
```

## 2. Put the firmware on the board

Plug the board in and put its serial port into a variable, so the commands below work
as written:

```bash
PORT=$(ls /dev/cu.usbserial-* | head -1)
echo "$PORT"
```

That should print one path, something like `/dev/cu.usbserial-1420` — the number differs
from board to board and from port to port, which is why nothing below spells it out. If
it prints nothing, see [Troubleshooting](#troubleshooting).

`PORT` only exists in the terminal window you typed it in; if you open a new one, set it
again.

### Option A — flash a ready-made image (no ESP-IDF)

Download `perch-esp32-*.bin` from the
[latest release](https://github.com/zeuscs09/perch/releases/latest). It is one file,
about 1 MB, containing the bootloader, the partition table and the app.

```bash
python3 -m pip install esptool
python3 -m esptool --chip esp32 --port "$PORT" \
    write_flash 0x0 ~/Downloads/perch-esp32-1.0.4.bin
```

That is the whole toolchain: about 10 MB of Python, no compiler. Skip to step 3.

### Option B — build it yourself

Take this route if you want to change the firmware, or if your board turns out to need
different panel settings.

Build tools:

```bash
brew install cmake ninja dfu-util python3
```

ESP-IDF — this is the big one, roughly 2 GB. v5.5 is what this firmware is built and
tested against; the component manifest accepts 5.4 and newer:

```bash
mkdir -p ~/esp && cd ~/esp
git clone -b v5.5 --recursive https://github.com/espressif/esp-idf.git
cd esp-idf && ./install.sh esp32
```

Then, from the repository, load the toolchain into your shell and flash:

```bash
cd firmware
. $HOME/esp/esp-idf/export.sh
idf.py -p "$PORT" flash monitor
```

The `export.sh` line is per-shell and is not permanent; open a new terminal and you run
it again. The first build takes several minutes. If anything here goes wrong, Espressif's
own [getting-started guide](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32/get-started/)
is the authority.

### Either way

The screen lights up and the board starts announcing itself over Bluetooth as
`perch-3f7a` — the last part comes from its MAC address, so you can tell two boards
apart. With `idf.py monitor` running you can watch it happen; press `Ctrl+]` to leave.

## 3. Install the Mac app

```bash
cd ../host
./Scripts/make-app.sh --install
```

This builds `Perch.app`, copies it to `/Applications`, and launches it. macOS asks
for Bluetooth permission the first time — say yes, or the app can never see the board.

A small mascot icon appears in your menu bar. Click it for the quota panel; click the
gear for settings. The foot of the panel tells you whether the board is connected and
what each session is doing.

The badge next to the icon is your session usage, and it turns red when you are burning
through the window faster than the clock is.

## 4. Connect it to Claude Code

Everything below is in **gear ▸ Settings… ▸ General**:

- **Install hooks in settings.json** — this is the one that matters. It teaches
  Claude Code to tell the app what it is doing. Nothing appears on the board without it.
  Your existing settings are kept, and a backup is written beside the file.
- **Board** — pick your board by name, or leave it on *Any board*.
- **Brightness** — the slider drives the screen's backlight.
- **Weather** — type a city, press Search, pick from the results. The sky above the mascots
  then follows the real one: cloud, rain, fog, and the time of day. Leave it off and the sky
  is a plain gradient that still tracks morning, day, dusk and night.
- **Launch at login** — so it is running before you start work.

Start a Claude Code session in any terminal — or `codex`, or `agy`. Within a second or two
something should start moving.

## 5. Quota on the board

The bars at the bottom of the screen have two independent sources, both optional:

- **Read quota from the statusline** (Settings ▸ General) installs a Claude Code statusline
  that hands the app your current usage. It needs no password, but it only updates while
  Claude Code is running.
- **Set session key…** (Settings ▸ General) lets the app ask claude.ai directly, so the
  number keeps moving even with Claude Code closed. **Refresh quota** then chooses how
  often (Off / 60s / 5 min).

> **About the session key.** It is the `sessionKey` cookie of a logged-in claude.ai
> browser session, and it is a **full-account credential** — anyone holding it can act as
> your account. The app stores it in `~/.perch/session-key` with mode 600 and never
> puts it in a command line, an environment variable, or a log. Take it out at any time
> by deleting that file, and revoke it by logging out of claude.ai in the browser you
> copied it from. If you would rather not, skip this — the statusline route above still
> shows a number.
>
> To get one: in your browser, open claude.ai while logged in → DevTools → Application →
> Cookies → `claude.ai` → copy the value of `sessionKey`.

Taking over the statusline slot never changes what you see: your own statusline command is
handed the same input and its output is printed as is. If you never had one, the app draws
this instead — the same elements, colours, and `~/.claude/statusline-config.txt` as the
statusline that ships with Claude Usage.

![The statusline the app draws: directory, branch, model, changed lines, token count, then the 5-hour and weekly quota bars with a pace mark and a reset countdown](docs/images/statusline.jpg)

## 6. Wi-Fi, so the screen survives Bluetooth (optional)

Bluetooth is the main path and always wins. It also drops — you walk past the board, the
Mac half-sleeps — and until now that left a frozen screen. Put the board on your network
and the app keeps feeding it when Bluetooth has been quiet for ten seconds.

**gear ▸ Settings… ▸ Wi-Fi**, with the board in Bluetooth range:

1. The list fills in as the *board* scans — not your Mac, so what you see is what the
   board can actually reach. It is 2.4 GHz only; a 5 GHz-only network will not appear.
2. Pick a network, type the password, **Connect**. macOS pairs with the board the first
   time; there is no six-digit code to enter.
3. It says `Connected to <name>` with the board's address. The board remembers up to five
   networks and comes back on its own after a power cut.

You do not have to configure anything on the Mac side. The snapshot is sealed with
AES-256-GCM under a key the app generates and pushes to the board over the same encrypted
channel as your Wi-Fi password, and the board is found over mDNS — the address box at the
bottom of the tab is only for networks that filter it.

The board still never talks to claude.ai; your session key never leaves the Mac.

## On the go

Both links so far assume the Mac and the board can reach each other: Bluetooth wants about
ten metres, and the LAN path wants the same network. Step outside either and the screen
stops moving. If you want it on a hotel desk or in a café, there are two routes — at very
different stages of proof.

Public Wi-Fi is not one of them. Captive portals need a browser the board does not have.
Use your phone's hotspot instead, which has no login page. And bring power: the case has
no battery, so a USB power bank is what keeps it alive.

**Route 1 — Tailscale.** Your phone shares a hotspot, the board joins it, the phone runs
Tailscale as a subnet router advertising that hotspot's subnet, and the Mac runs with
`--accept-routes`. The Mac then reaches the board at its hotspot address as though it were
sitting on your LAN — nothing to run, nothing to host. Two catches: **the phone has to be
Android**, because iOS cannot act as a subnet router, and the hotspot subnet must not
collide with your home one. Tested on foot a long way from home, with the screen still
updating.

**Route 2 — a relay you run.** The board dials *out* to a relay, the Mac dials *out* to the
same relay, and they meet in the middle, so NAT stops being a problem for either side. Any
phone's hotspot works and Tailscale is not involved.

The relay holds no key. The payload is sealed with AES-256-GCM before it leaves either
end, so the relay only ever moves ciphertext and needs no TLS of its own — which is what
makes this fit at all: a TLS handshake wants 20–40 KB, the board's lowest measured free
heap is 26.8 KB, and an outbound TCP socket costs 556 bytes. [`relay/perch-relay.py`](relay/perch-relay.py)
is about 140 lines with no dependencies.

```bash
defaults write com.perch.daemon relayHost <your relay's address>
defaults write com.perch.daemon relayPort -int 7333
```

There is no default address, and an empty one disables the route. A relay is somebody's
server; shipping one as a factory default would point every board cloned from this repo at
a machine whose owner never agreed to it.

> **Where route 2 actually stands.** The board half is proven — it dialled out from a phone
> hotspot on a mobile IP, and the address survives reflashing firmware built without it.
> The Mac half has never once executed, because the direct LAN path won every time it was
> tested. The code is written and reads correctly, which is not the same as working. If you
> try it, [issue #1](https://github.com/zeuscs09/perch/issues/1) is where to say what
> happened.

## Troubleshooting

**No `/dev/cu.usbserial-*` when the board is plugged in.**
Usually the cable — many micro-USB cables carry power only. Failing that, the board's
USB-serial chip (CH340) may need a driver on older macOS releases.

**Flashing stops at "Connecting........".**
Hold the **BOOT** button on the board, start `idf.py flash`, and release it once the log
says `Connecting`. Also close any serial monitor still holding the port.

**The screen is on but the colours are wrong, or the image is mirrored.**
Some batches of this board ship a different panel than the one this firmware was measured
against. Run the probe project in `firmware/probe/` to read out what your panel actually
reports, then change the two constants it disagrees with in `firmware/main/pch_lcd.c`:
the `0x36` (MADCTL) value for orientation and mirroring, and `0x20` (inversion off) versus
`0x21` (inversion on) for inverted colours.

**The board never shows up in the Board menu.**
Check that the app has Bluetooth permission in System Settings → Privacy & Security →
Bluetooth, that the board is powered, and that nothing else is connected to it — the
firmware accepts exactly one connection at a time.

**macOS asks for Bluetooth permission again after every rebuild.**
Expected. The app is signed ad-hoc, so each build is a new identity as far as macOS is
concerned. There is no way around it without an Apple Developer ID.

**The mascot never moves.**
The hooks are probably not installed — Settings ▸ General → *Install hooks in
settings.json*. Sessions already open when you install them keep the old settings; start
a new one. *Open log* in the same tab shows what the app is receiving.

**The Wi-Fi list stays empty, or the spinner never stops.**
Wi-Fi is set up over Bluetooth, so the board has to be connected first — the tab says so
when it is not. The list only ever holds 2.4 GHz networks.

**The board is on the network and pings, but the screen still freezes when Bluetooth
goes.**
macOS 15 and newer ask for Local Network permission separately, and a refusal silences
both mDNS and direct connections with no error at all. System Settings ▸ Privacy &
Security ▸ Local Network.

## Known limits

- **macOS only.** The app that talks to Claude Code is a Swift menu bar app; there is no
  Linux or Windows build.
- **No over-the-air updates.** New firmware means plugging the USB cable back in.
- **The speaker is unused.** The board has a speaker pin; nothing is wired up to it yet.
- **Ad-hoc signing.** The app is not notarised, so it is built per-machine rather than
  handed around.

## Credit

Perch is a fork of [TamaClaude](https://github.com/thaitop/tamaclaude) by Uthai Moolpak,
which is where the board bring-up, the rectangle renderer, and the BLE protocol came from.
It was renamed because what it does drifted a long way from raising a virtual pet: it is
now a status display, a clock, and a weather panel that happens to know about your agents.
Fixes that apply to both projects still go upstream as pull requests.

## License

MIT — see [LICENSE](LICENSE).
