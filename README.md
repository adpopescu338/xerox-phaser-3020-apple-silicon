# Xerox Phaser 3020 on Apple Silicon macOS (USB, no VM)

Make a **Xerox Phaser 3020** print over **USB** from a modern **Apple Silicon Mac**,
even though Xerox never shipped a driver for Apple Silicon or for macOS newer than
Monterey (12).

> **Verified:** USB printing on an **M5 MacBook Air running macOS 27.0.1**, confirmed
> by the user after applying the updated launchers. The PDF → raster → SPL pipeline
> also passes locally. The original setup was verified over USB on macOS 26.x.

**Compatibility:** any Apple Silicon Mac — **M1, M2, M3, M4, M5** — on a modern macOS that still
has **Rosetta 2** and **CUPS PPD/filter support** (including macOS 27 *Golden Gate*).
Apple documents general Rosetta support through macOS 27; do not assume this Intel driver
will work on macOS 28. See [Apple’s Rosetta guidance](https://support.apple.com/en-us/102527). Also works on **Intel Macs**, where the
filter runs natively without Rosetta. Because the 3020 is a rebadged **Samsung** engine, this
approach is a useful template for other host-based Samsung/Xerox **SPL** printers too (e.g.
Samsung **M2020 / M2022 / M2070**, Xerox **Phaser 3052 / 3260**).

---

## TL;DR — quick start

```bash
git clone https://github.com/adpopescu338/xerox-phaser-3020-apple-silicon.git
cd xerox-phaser-3020-apple-silicon
./bootstrap.sh           # installs Rosetta 2 if needed, installs the driver, creates the queue
./scripts/wake-and-print.sh   # prints a test page (wake the printer when prompted)
```

After this, the printer shows up as **Xerox Phaser 3020** in any app's print dialog (⌘P).

---

## The problem

The Phaser 3020 is a **host-based printer**. It has *no* page-description language of its
own — no PostScript, no PCL. The computer must rasterize every page and send the printer a
stream in **SPL (Samsung Printer Language)**. (The 3020 is a rebadged Samsung; its USB
vendor ID is `0x0924`, Samsung Electronics. Xerox licensed Samsung's print engine.)

That means **you cannot use a generic driver.** You need software that:

1. turns the page into a raster bitmap, then
2. encodes that bitmap as SPL the printer understands.

Xerox/Samsung only ever shipped that software (a CUPS filter called **`rastertosec`**) as an
**Intel (x86_64) binary**, in a macOS driver that stops at **macOS 12 Monterey**. On an
Apple Silicon Mac running a current macOS, that installer won't run and there is no native
arm64 replacement. Hence "no driver."

## The key insight (the actual fix)

macOS **already contains everything needed to print** — the CUPS printing system and the
PDF→raster pipeline (`cgpdftoraster`) are built in. The *only* missing piece is the SPL
encoder. And that missing piece already exists: it's Xerox/Samsung's own **`rastertosec`**
filter — an **x86_64 Mach-O** executable.

Apple Silicon Macs can run x86_64 binaries through **Rosetta 2**. A CUPS filter is a
program that reads on stdin and writes on stdout. On the macOS 27.0.1 setup checked here,
CUPS rejected the bundled universal Intel/i386 executables with `Bad CPU type in executable`,
while explicitly selecting x86_64 worked.
So:

> **We run the vendor's own SPL rasterizer under Rosetta 2.**
> Full vendor-fidelity output, no reverse-engineering of the protocol, no VM.

The print pipeline becomes:

```
   App (⌘P)
     │  PDF
     ▼
  cgpdftoraster        ← built into macOS (native arm64)
     │  CUPS raster
     ▼
  rastertosec          ← Xerox/Samsung's Intel filter, run via Rosetta 2  ★ the missing piece
     │  SPL
     ▼
  usb:// backend       ← built into macOS
     │
     ▼
  Xerox Phaser 3020
```

Why this is robust: it uses the manufacturer's *own* rasterizer, so output quality matches
the official driver exactly. It depends only on (a) Rosetta 2 and (b) CUPS's PPD-driver
support — see [Longevity & alternatives](#longevity--alternatives) for what to do if either
goes away.

---

## How it works in detail

The vendor PPD (`driver/Xerox_Phaser_3020.ppd`) wires the filter in by **absolute path**:

```
*cupsFilter: "application/vnd.cups-raster 0 /Library/Printers/Xerox/P3020/rastertosec"
*cupsFilter: "application/vnd.cups-command 100 /Library/Printers/Xerox/P3020/commandtosec"
```

So the install simply:

1. Copies the original filters as `*.bin` to `/Library/Printers/Xerox/P3020/` and installs
   shell launchers at the original PPD paths. Each runs `/usr/bin/arch -x86_64 "$0.bin" "$@"`.
   - `rastertosec`   — raster → SPL (the core filter)
   - `prefilter`     — vendor pre-processing helper
   - `commandtosec`  — maintenance commands (clean/align)
   - `SCMS/`         — screening/halftone tables the filter loads at runtime
2. Generates an installation PPD without references to unbundled legacy GUI plugins,
   utilities, and icons, then places it in the system PPD repository. The vendor original
   and its checksum stay unchanged.
3. Creates a CUPS queue bound to the printer's `usb://…` device URI.

The explicit architecture selection lets macOS run the Intel filters under Rosetta when
CUPS invokes the launchers. Intel Macs use the same launchers without translation.

### How this was figured out (transferable method)

If you're adapting this to a newer macOS, a different printer, or rebuilding from scratch,
this is the diagnostic path that found the fix:

```bash
# 1. Identify the device and how CUPS sees it
system_profiler SPUSBDataType            # vendor/product (0x0924 = Samsung silicon)
lpinfo -v                                # -> direct usb://Xerox/Phaser%203020?serial=...

# 2. Confirm it's host-based SPL (no PostScript/PCL) -> needs a rasterizing driver
#    (known for this model; rebadged Samsung)

# 3. Get the last vendor macOS driver, extract the CUPS filter + PPD
hdiutil attach Xerox_Phaser_3020_Driver_1.06.00.dmg
unzip "…/Printer Driver.zip"             # filters live under "Filter- SPL/" and "Command File Filter/"

# 4. Verify the filter has an x86_64 slice (Rosetta-runnable) and check its libs
lipo -archs rastertosec                  # -> x86_64 i386   ✅ (i386 is dead on arm64; x86_64 runs via Rosetta)
otool -L rastertosec                     # -> /usr/lib/libcups.2.dylib, libcupsimage.2.dylib, …

# 5. Prove it actually loads under Rosetta before installing anything
arch -x86_64 ./rastertosec </dev/null    # -> prints a CUPS usage line (NOT a dyld "image not found")
```

If step 4 shows **only `i386`** (no x86_64), Rosetta can't help — that driver is too old.
If step 5 shows a `dyld: Library not loaded` error, a system library the filter needs was
removed from macOS and you'd need to supply it.

---

## Prerequisites

- Apple Silicon Mac (also works on Intel Macs — there the filter runs natively, no Rosetta).
- macOS with the built-in CUPS printing system (every macOS has it).
- **Rosetta 2** (Apple Silicon only). `bootstrap.sh` installs it automatically if missing,
  or do it yourself: `softwareupdate --install-rosetta --agree-to-license`.
- The printer connected by USB and powered on.

---

## Install

### Automatic

```bash
./bootstrap.sh
```

It checks your Mac, installs Rosetta 2 if needed, auto-detects the printer's USB URI
(so it works regardless of the unit's serial number), installs the driver, and creates the
queue. Re-runnable — it updates an existing queue in place without deleting queued jobs.
It tests Intel execution and filter loading rather than checking Rosetta folders/processes.
If several Phaser 3020 units are connected, it asks you to rerun with `URI` set to one of
the listed device URIs. `QUEUE` can override the default queue name.

### Manual (if the script ever breaks on a future macOS)

```bash
DEST=/Library/Printers/Xerox/P3020
sudo install -d -m 755 "$DEST/SCMS"
for filter in rastertosec prefilter commandtosec; do
  sudo install -m 755 "driver/$filter" "$DEST/$filter.bin"
  sudo install -m 755 scripts/filter-launcher.sh "$DEST/$filter"
done
sudo install -m 755 driver/SCMS/libscmssc.dylib "$DEST/SCMS/"
sudo install -m 644 driver/SCMS/P3020sc.cts "$DEST/SCMS/"
sudo xattr -dr com.apple.quarantine "$DEST"

# Generate the PPD without references to absent vendor GUI components.
./scripts/prepare-ppd.sh > /tmp/Xerox_Phaser_3020.ppd
sudo install -d -m 755 /Library/Printers/PPDs/Contents/Resources
sudo install -m 644 /tmp/Xerox_Phaser_3020.ppd \
  "/Library/Printers/PPDs/Contents/Resources/Xerox Phaser 3020"

# Copy your printer's exact USB URI from this list:
lpinfo -v
URI='usb://Xerox/Phaser%203020?serial=YOUR_SERIAL'
sudo lpadmin -p Xerox_Phaser_3020 -E -v "$URI" -P /tmp/Xerox_Phaser_3020.ppd \
  -D "Xerox Phaser 3020 (SPL via Rosetta 2)" -L USB
sudo cupsenable Xerox_Phaser_3020
sudo cupsaccept Xerox_Phaser_3020
```

---

## Testing

Read-only installation and connection checks:

```bash
./bootstrap.sh --check
```

Exercise the real macOS PDF → raster → SPL pipeline in a temporary directory, with no
installation, administrator password, or print job:

```bash
./test/check-pipeline.sh
```

Send a physical test page after installation:

```bash
./scripts/wake-and-print.sh
```

It waits for the printer to appear on USB (wake it with a button press if asleep), then
prints `test/test-page.pdf`. Or just print anything from any app and pick **Xerox Phaser 3020**.

---

## Troubleshooting

**"The printer is offline" / job stuck / `getDeviceStatusInfoWithURI : Connection Fail`**
The Phaser 3020 powers down its USB interface in energy-save sleep and then **drops off the
USB bus entirely**. Waking it by sending a job is often *not* enough — press a button on the
printer to wake it, confirm the ready LED is steady, then retry. Verify it's actually on the
bus:

```bash
ioreg -p IOUSB -w 0 | grep -i phaser     # nothing = not on the bus (asleep/off/cable)
lpinfo -v | grep -i phaser               # nothing = CUPS can't see it either
```

Clear a stuck job with `cancel -a Xerox_Phaser_3020`.

**Plug it straight into the Mac**, not through a hub, while getting it working.

**`Bad CPU type in executable` / `com.apple.badarch-error`:** rerun `./bootstrap.sh`
to install the explicit x86_64 launchers. A successful `arch -x86_64` test of the raw
binary alone does not prove CUPS can launch it directly. `./bootstrap.sh --check` checks
that the launcher is installed too.

**Nothing prints but no error:** check the filter still loads under Rosetta:
```bash
/Library/Printers/Xerox/P3020/rastertosec </dev/null   # should print a usage line
```
and watch the log: `log show --predicate 'process == "cupsd"' --last 2m` or
`tail -f /var/log/cups/error_log` (needs sudo).

**Gatekeeper / quarantine** can block the downloaded binaries. The installer clears it; if you
copied files by hand, run `sudo xattr -dr com.apple.quarantine /Library/Printers/Xerox/P3020`.

---

## Longevity & alternatives

This relies on Intel translation and CUPS PPD/filter support:

- **macOS 28 and later:** Apple says general Rosetta support ends after macOS 27
  ([source](https://support.apple.com/en-us/102527)). This Intel filter is not a supported
  solution for that release. Native SPL drivers or a separate compatible print server
  would need model-specific testing; this repo does not supply either.
- **If CUPS drops PPD/filter drivers** (CUPS has deprecated them): use the printer's
  **AirPrint over Wi-Fi** instead — put the 3020 on your network and macOS drives it with
  **zero drivers**, future-proof across OS upgrades. (Note: the 3020's AirPrint is Wi-Fi
  only; its USB interface is raw SPL, no IPP-over-USB — so AirPrint is the alternative *to*
  USB, not over it.)

For "I just changed Macs and want USB working again," this repo is the fastest path; AirPrint
is the most upgrade-proof long term.

---

## Updating the bundled driver

To re-extract the driver from a fresh Xerox DMG (e.g. a newer version):

```bash
./scripts/extract-driver.sh /path/to/Xerox_Phaser_3020_Driver_X.dmg
# or, with no argument, it downloads the known version and extracts it
```

This rewrites `driver/` and prints fresh checksums to paste into `driver/SOURCE.md`.

---

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the queue, the filters under `/Library/Printers/Xerox/P3020`, and the installed PPD.

---

## Repository layout

```
.
├── README.md                 # this file — the concept and the steps
├── bootstrap.sh              # one-command install (Rosetta + driver + queue)
├── driver/                   # the bundled Xerox/Samsung driver (see driver/SOURCE.md)
│   ├── rastertosec           #   raster -> SPL  (the missing piece)
│   ├── prefilter
│   ├── commandtosec
│   ├── SCMS/                 #   screening/halftone tables
│   ├── Xerox_Phaser_3020.ppd
│   └── SOURCE.md             # provenance, attribution, checksums, download link
├── scripts/
│   ├── doctor.sh             # read-only installation/USB checks
│   ├── filter-launcher.sh    # select the Intel 64-bit slice explicitly
│   ├── prepare-ppd.sh        # omit absent legacy GUI components
│   ├── uninstall.sh
│   ├── wake-and-print.sh     # detect/wake printer, print the test page
│   └── extract-driver.sh     # rebuild driver/ from a vendor DMG
├── test/
│   ├── check-pipeline.sh     # render to SPL without installation or printing
│   ├── test-page.pdf
│   └── test-page.ps
├── LICENSE                   # MIT — covers the scripts/docs ONLY, not driver/
└── NOTICE                    # attribution for the bundled driver
```

## Credits & license

The **scripts and documentation** here are MIT-licensed (see [LICENSE](LICENSE)).

The contents of **`driver/`** are **not** mine and **not** open source — they are the
proprietary work of **Xerox Corporation** and **Samsung Electronics**, redistributed here for
convenience and preservation. See [`driver/SOURCE.md`](driver/SOURCE.md) and [NOTICE](NOTICE)
for full attribution, the official download link, and the license caveat.

---

<sub>**Keywords:** Xerox Phaser 3020 macOS driver · Apple Silicon M1 M2 M3 M4 · macOS Tahoe 26
Sequoia 15 Sonoma 14 · print over USB with no driver · "no driver for Mac" · Rosetta 2 x86_64
CUPS filter · SPL Samsung Printer Language · host-based / GDI printer · `rastertosec` · Samsung
M2020 M2022 M2070 · Xerox Phaser 3052 3260 · driverless printing · arm64 · printer offline /
not working on Mac · install Phaser 3020 without a virtual machine.</sub>
