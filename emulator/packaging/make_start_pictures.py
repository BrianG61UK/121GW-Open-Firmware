"""make_start_pictures.py - draw the pictures of emulator/START.md (SVG drawings of the dialogs, the control to click ringed).

    python3 -I emulator/packaging/make_start_pictures.py emulator/docs/start

Standard library only.  The pictures are drawings, not screenshots (each says so).
"""
import html, os, sys
OUT = sys.argv[1]
FONT = "font-family='-apple-system,Segoe UI,Helvetica,Arial,sans-serif'"

def esc(t): return html.escape(t, quote=True)

class Pic:
    def __init__(self, w, h, bg='#eef1f4'):
        self.w, self.h, self.items = w, h, [f"<rect width='{w}' height='{h}' fill='{bg}'/>"]
    def rect(self, x, y, w, h, fill='#fff', stroke='#c8cdd2', r=10, sw=1):
        self.items.append(f"<rect x='{x}' y='{y}' width='{w}' height='{h}' rx='{r}' fill='{fill}' stroke='{stroke}' stroke-width='{sw}'/>")
    def text(self, x, y, t, size=15, weight='normal', color='#1d1d1f', anchor='start'):
        self.items.append(f"<text x='{x}' y='{y}' font-size='{size}' font-weight='{weight}' fill='{color}' text-anchor='{anchor}' {FONT}>{esc(t)}</text>")
    def lines(self, x, y, ts, size=14, color='#3a3a3c', gap=20, anchor='start'):
        for i, t in enumerate(ts): self.text(x, y + i * gap, t, size, color=color, anchor=anchor)
    def button(self, x, y, w, h, t, fill='#fff', color='#1d1d1f', r=7, size=14, stroke='#c8cdd2'):
        self.rect(x, y, w, h, fill, stroke, r)
        self.text(x + w / 2, y + h / 2 + 5, t, size, color=color, anchor='middle')
    def ring(self, x, y, w, h, n=None, label=None, side='right'):
        self.items.append(f"<rect x='{x-7}' y='{y-7}' width='{w+14}' height='{h+14}' rx='12' fill='none' stroke='#e01e1e' stroke-width='4'/>")
        if n is not None:
            cx = x + w + 30 if side == 'right' else x - 30
            cy = y + h / 2
            self.items.append(f"<circle cx='{cx}' cy='{cy}' r='16' fill='#e01e1e'/>")
            self.text(cx, cy + 6, str(n), 17, 'bold', '#fff', 'middle')
            if label:
                self.text(cx + (24 if side == 'right' else -24), cy + 6, label, 15, 'bold', '#e01e1e', 'start' if side == 'right' else 'end')
    def caption(self, t):
        self.text(self.w / 2, self.h - 14, t, 13, color='#6e6e73', anchor='middle')
    def save(self, name):
        body = '\n'.join(self.items)
        open(os.path.join(OUT, name), 'w').write(f"<svg xmlns='http://www.w3.org/2000/svg' width='{self.w}' height='{self.h}' viewBox='0 0 {self.w} {self.h}'>\n{body}\n</svg>\n")

def window(p, x, y, w, h, title='', mac=True):
    p.rect(x, y, w, h, '#fff', '#b9bfc6', 12)
    if mac:
        for i, c in enumerate(('#ff5f57', '#febc2e', '#28c840')):
            p.items.append(f"<circle cx='{x+20+i*20}' cy='{y+18}' r='6' fill='{c}'/>")
        if title: p.text(x + w / 2, y + 23, title, 13, 'bold', '#3a3a3c', 'middle')
    else:
        p.rect(x, y, w, 34, '#f3f3f3', '#b9bfc6', 0)
        if title: p.text(x + 14, y + 22, title, 13, color='#3a3a3c')
        p.text(x + w - 22, y + 23, '✕', 14, color='#555', anchor='middle')

# 1 downloads
p = Pic(860, 390)
p.text(30, 40, 'github.com/zombu4/121GW-Open-Firmware/releases  →  latest release  →  Assets', 15, 'bold')
rows = [('Mac with Apple chip (M1, M2, M3, M4 …)', '…-macos-arm64.dmg'),
        ('Windows 10 / 11', '…-windows-x64.exe'), ('Ubuntu, Debian, Mint, Pop!_OS', '…-linux-amd64.deb'),
        ('any other Linux (x86-64)', '…-linux-x86_64.AppImage')]
for i, (who, f) in enumerate(rows):
    y = 70 + i * 54
    p.rect(30, y, 800, 44, '#fff')
    p.text(50, y + 28, who, 15)
    p.text(470, y + 28, '121GW-Open-Firmware-Emulator-v…' + f[1:], 14, 'bold', '#0969da')
p.text(30, 355, 'Click the one line for your computer. The files ending in .sha256 are not needed.', 14, color='#3a3a3c')
p.caption('Drawing, not a screenshot')
p.save('01-download.svg')

# mac dmg drag
p = Pic(760, 330)
window(p, 90, 30, 580, 260, '121GW-Open-Firmware-Emulator')
p.rect(170, 100, 110, 110, '#ffd7a8', '#e8a35a', 22); p.text(225, 165, '121GW', 18, 'bold', '#7a3d00', 'middle')
p.text(225, 240, '121GW Emulator', 14, anchor='middle')
p.rect(480, 100, 110, 110, '#cfe3ff', '#7aa7e0', 22); p.text(535, 165, 'A', 30, 'bold', '#1c5fb8', 'middle')
p.text(535, 240, 'Applications', 14, anchor='middle')
p.items.append("<path d='M300 155 L455 155' stroke='#e01e1e' stroke-width='5' marker-end='url(#a)'/>")
p.items.insert(1, "<defs><marker id='a' markerWidth='10' markerHeight='10' refX='6' refY='5' orient='auto'><path d='M0,0 L10,5 L0,10 z' fill='#e01e1e'/></marker></defs>")
p.text(378, 140, 'drag', 15, 'bold', '#e01e1e', 'middle')
p.caption('Double-click the downloaded .dmg, then drag the app onto Applications.  Drawing, not a screenshot')
p.save('03-mac-drag.svg')

# mac not opened
p = Pic(760, 360)
p.rect(200, 25, 360, 300, '#f6f6f6', '#c8cdd2', 16)
p.rect(345, 45, 70, 70, '#ffd7a8', '#e8a35a', 16); p.text(380, 88, '121GW', 13, 'bold', '#7a3d00', 'middle')
p.text(380, 145, '"121GW Emulator" Not Opened', 16, 'bold', anchor='middle')
p.lines(380, 172, ['Apple could not verify "121GW Emulator" is', 'free of malware that may harm your Mac or', 'compromise your privacy.'], 13, anchor='middle')
p.button(230, 240, 300, 30, 'Done', '#0a84ff', '#fff')
p.ring(230, 240, 300, 30, 1, 'click Done', 'right')
p.button(230, 278, 300, 30, 'Move to Trash')
p.caption('The first start of an app from the internet.  Drawing, not a screenshot')
p.save('04-mac-not-opened.svg')

# mac settings open anyway
p = Pic(860, 400)
window(p, 40, 25, 780, 340, 'Privacy & Security')
p.rect(52, 50, 190, 305, '#f2f2f4', '#e0e0e0', 8)
p.lines(70, 85, ['Wi-Fi', 'Bluetooth', 'Network', 'General', 'Appearance', 'Privacy & Security', 'Desktop & Dock'], 14, gap=30)
p.ring(64, 225, 150, 22, 1, None, 'right')
p.text(270, 85, 'Security', 16, 'bold')
p.rect(265, 100, 535, 110, '#fff')
p.lines(285, 130, ['Allow applications from', 'App Store & Known Developers'], 14, gap=22)
p.lines(285, 185, ['"121GW Emulator" was blocked to protect your Mac.'], 14)
p.button(660, 168, 120, 28, 'Open Anyway')
p.ring(660, 168, 120, 28)
p.items.append("<circle cx='748' cy='232' r='16' fill='#e01e1e'/>")
p.text(748, 238, '2', 17, 'bold', '#fff', 'middle')
p.lines(270, 260, ['(scroll down to "Security" if you do not see it)'], 13, color='#6e6e73')
p.caption('Apple menu  →  System Settings  →  Privacy & Security.  Drawing, not a screenshot')
p.save('05-mac-open-anyway.svg')

# mac confirm
p = Pic(760, 340)
p.rect(200, 25, 360, 280, '#f6f6f6', '#c8cdd2', 16)
p.rect(345, 45, 70, 70, '#ffd7a8', '#e8a35a', 16); p.text(380, 88, '121GW', 13, 'bold', '#7a3d00', 'middle')
p.text(380, 145, 'Open "121GW Emulator"?', 16, 'bold', anchor='middle')
p.lines(380, 172, ['Only open it if you trust its source.'], 13, anchor='middle')
p.button(230, 218, 300, 30, 'Open Anyway', '#0a84ff', '#fff')
p.ring(230, 218, 300, 30, 3, 'click, then your password', 'right')
p.button(230, 256, 300, 30, 'Cancel')
p.caption('Only the first time. Afterwards it opens like any app.  Drawing, not a screenshot')
p.save('06-mac-confirm.svg')

# windows browser keep
p = Pic(860, 300)
window(p, 60, 25, 740, 240, 'Downloads', mac=False)
p.rect(80, 75, 700, 100, '#fff')
p.text(100, 105, '121GW-Open-Firmware-Emulator-v…-windows-x64.exe', 14, 'bold')
p.text(100, 130, "isn't commonly downloaded. Make sure you trust it before you open it.", 13, color='#3a3a3c')
p.button(600, 140, 70, 26, '•••'); p.ring(600, 140, 70, 26, 1, None, 'left')
p.button(680, 140, 90, 26, 'Delete')
p.lines(100, 205, ['Only if the browser shows this: click  •••  →  Keep  →  Show more  →  Keep anyway.'], 14, color='#1d1d1f')
p.caption('Microsoft Edge download list (Chrome: "Keep").  Drawing, not a screenshot')
p.save('07-win-browser-keep.svg')

# windows smartscreen 1
p = Pic(760, 380)
p.rect(130, 20, 500, 340, '#1f5fa8', '#1f5fa8', 4)
p.text(160, 70, 'Windows protected your PC', 24, 'bold', '#fff')
p.lines(160, 110, ['Microsoft Defender SmartScreen prevented an unrecognized', 'app from starting. Running this app might put your PC at risk.'], 14, '#fff', 22)
p.text(160, 175, 'More info', 15, 'bold', '#fff'); p.items.append("<line x1='160' y1='180' x2='228' y2='180' stroke='#fff'/>")
p.ring(156, 158, 76, 26, 1, 'click More info', 'right')
p.button(500, 310, 110, 32, "Don't run", '#e1e1e1', '#000', 2)
p.caption('Drawing, not a screenshot')
p.save('08-win-smartscreen-1.svg')

p = Pic(760, 380)
p.rect(130, 20, 500, 340, '#1f5fa8', '#1f5fa8', 4)
p.text(160, 70, 'Windows protected your PC', 24, 'bold', '#fff')
p.lines(160, 110, ['Microsoft Defender SmartScreen prevented an unrecognized', 'app from starting. Running this app might put your PC at risk.'], 14, '#fff', 22)
p.lines(160, 170, ['App:          121GW-Open-Firmware-Emulator-v…-windows-x64.exe', 'Publisher:   Unknown publisher'], 13, '#fff', 22)
p.button(370, 310, 120, 32, 'Run anyway', '#e1e1e1', '#000', 2)
p.ring(370, 310, 120, 32, 2, None, 'left')
p.button(500, 310, 110, 32, "Don't run", '#e1e1e1', '#000', 2)
p.caption('Drawing, not a screenshot')
p.save('09-win-smartscreen-2.svg')

# windows installer
p = Pic(860, 400)
window(p, 120, 20, 620, 350, 'Setup - 121GW Emulator', mac=False)
p.text(150, 85, 'Select Additional Tasks', 17, 'bold')
p.text(150, 112, 'Additional icons:', 14, color='#3a3a3c')
p.rect(170, 128, 18, 18, '#0067c0', '#0067c0', 3); p.text(179, 143, '✓', 14, 'bold', '#fff', 'middle')
p.text(200, 143, 'Create a desktop icon', 14)
p.ring(166, 124, 200, 26, 2, 'leave ticked', 'right')
p.button(520, 320, 95, 30, 'Next >', '#0067c0', '#fff', 4); p.ring(520, 320, 95, 30, 3, None, 'left')
p.button(630, 320, 95, 30, 'Cancel', '#fff', '#000', 4)
p.lines(150, 200, ['Before this page: "I accept the agreement"  (1)  →  Next.', 'After it: Install, then Finish with', '"Start the 121GW emulator now" ticked.'], 14, gap=24)
p.caption('No administrator password is needed.  Drawing, not a screenshot')
p.save('10-win-installer.svg')

# linux deb
p = Pic(860, 360)
window(p, 60, 20, 740, 300, 'App Center', mac=False)
p.rect(90, 75, 90, 90, '#ffd7a8', '#e8a35a', 18); p.text(135, 127, '121GW', 15, 'bold', '#7a3d00', 'middle')
p.text(200, 105, '121gw-emulator', 20, 'bold')
p.text(200, 132, 'Emulator of the EEVblog 121GW multimeter', 14, color='#3a3a3c')
p.button(200, 150, 110, 32, 'Install', '#e95420', '#fff', 6); p.ring(200, 150, 110, 32, 2, 'then your password', 'right')
p.lines(90, 230, ['(1) In the Files app: right-click the .deb  →  Open With App Center  (or double-click it).',
                  'Afterwards: Show Apps  →  121GW Emulator.  Terminal instead:  sudo apt install ./121GW-…-linux-amd64.deb'], 14, gap=26)
p.caption('Ubuntu App Center.  Drawing, not a screenshot')
p.save('11-linux-deb.svg')

# linux appimage
p = Pic(760, 340)
window(p, 120, 20, 520, 290, 'Properties', mac=False)
p.text(150, 80, '121GW-Open-Firmware-Emulator-v…-linux-x86_64.AppImage', 13, 'bold')
p.text(150, 125, 'Executable as Program', 14)
p.rect(560, 110, 46, 24, '#3584e4', '#3584e4', 12); p.items.append("<circle cx='594' cy='122' r='9' fill='#fff'/>")
p.ring(556, 106, 54, 32, 2, None, 'left')
p.lines(150, 190, ['(1) Right-click the file  →  Properties.', '(3) Close, then double-click the file.', 'Older systems: tab "Permissions",', '"Allow executing file as program".'], 14, gap=24)
p.caption('Files (GNOME).  Drawing, not a screenshot')
p.save('12-linux-appimage.svg')

# emulator window load firmware
p = Pic(900, 420)
window(p, 30, 15, 840, 380, '121GW Emulator')
p.rect(60, 55, 300, 320, '#2b3238', '#2b3238', 18); p.text(210, 140, '1.5000', 34, 'bold', '#d7f3d0', 'middle'); p.text(210, 175, 'the meter', 14, color='#9aa4ad', anchor='middle')
p.rect(390, 55, 450, 320, '#20262b', '#20262b', 10)
p.text(410, 85, 'Pause    Power cycle', 13, color='#e6eaee')
p.text(410, 125, 'firmware', 14, color='#e6eaee')
p.button(480, 108, 230, 26, '2_fast - fast ▾', '#2b3238', '#e6eaee', 6, 12, '#3a434a')
p.button(480, 145, 200, 28, 'Load firmware file…', '#2b3238', '#e6eaee', 6, 13, '#3a434a')
p.ring(480, 145, 200, 28, 1, 'your EEVBlog.bin', 'right')
p.button(410, 190, 120, 26, 'Quit emulator', '#2b3238', '#e6eaee', 6, 12, '#3a434a')
p.lines(410, 245, ['… or drag the .bin file onto the window.', 'The meter restarts with it; a file that is not', 'a 121GW firmware is refused with the reason.'], 13, '#c9d1d9', 22)
p.caption('Drawing, not a screenshot')
p.save('13-load-firmware.svg')
print('ok')
