# State and commands for the page

`GET /state?since=T` returns the JSON below; `POST /api` takes one command object and needs the request header
`X-121GW-Companion: 1` (without it: 403, nothing is sent to the meter).  Every command answers `{"ok": true, ...}` or
`400 {"error": "text"}`.  The keys that existed before (`now`, `link`, `meter`, `update`, `clock`, `session`, `folder`)
are unchanged; the keys here are new.

## Parameters

A command is an object whose first key names it: `{"connect": address}`.  Parameters of the new commands go beside the
command key, `{"card_download": true, "name": "LOG0001.CSV", "dest": "/path"}`; they are also accepted inside it,
`{"card_download": {"name": "...", "dest": "..."}}`.

## state.derived  (computed here from the decoded reading; `null` = cannot be told)

    { rel_pct,        % change against the value when REL went on; null when REL is off, when the program connected with REL
                      already on (reference unknown), or when the reference is 0
      loop_pct,       % of the loop range, DC current modes only (DCuA, DCmA, DCA), null while REL is on; can be < 0 or > 100
      loop_range,     "4-20" | "0-20"   (the user's choice, default "4-20")
      pt_c,           degC of the sensor from the resistance (OHM mode, only when pt_type is set; -200..850, else null)
      pt_type,        null | "Pt100" | "Pt1000"
      limit: { lo, hi,      the user's limits as given (either may be null), in `unit`
               unit,        unit of lo / hi (null while no limit is set)
               verdict }    "PASS" | "HI" | "LO" | null (null: no limit, other quantity than the limit's, overload
                            (its sign is not in the frame), or REL on) }

Command `set_derived`: any of `loop_range`, `pt_type` (null switches off), `limit` (`{lo, hi, unit}`, null clears;
unit such as `V`, `mV`, `A`, `mA`, `ohm`, `kohm`, `Hz`, `degC`; omitted = the unit of the present reading); returns
`{"ok": true, "derived": {...}}`.  Stored in the program's settings file.

## state.desk  (bool)

`true` while the meter shows the SETUP page Ld (no status frames; the page answers the transfer's status request).  Needed
for the card, settings and diagnosis commands; the key command is refused while it is `true`.  Becomes `true` a few
seconds after the last status frame, `false` with the first status frame.

## Remote keys

`{"key": "REL", "long": false}`  keys: `RANGE HOLD REL PEAK MODE MINMAX MEM SETUP` (any case; `MIN/MAX` also).  Answers
`{"ok": true, "key", "long"}` after the meter echoed the key frame.  Errors: on page Ld, during an update or card
operation, in the bootloader's update mode, no echo.  A remote SETUP is refused by the meter while logging and starts an
offset calibration in calibration mode: confirm it in the page.

## state.diag

    { values: [21 numbers] | [] before the first read, text: readable explanation }

Command `diag_read` (page Ld needed): reads STATUS 0..20; answers `{"ok": true, "diag": {...}}`.

## state.card

    { files: [{name, size, date "YYYY-MM-DD" | "", time "HH:MM:SS" | ""}],   last list (card_list; refreshed by card_delete)
      free_bytes, total_bytes,      numbers | null until card_info
      busy, op,                     bool; "list" | "info" | "download" | "delete" | "sync" while busy, else ""
      progress,                     0..1 of the running download or sync
      sync: { folder, last "YYYY-MM-DD HH:MM:SS" | null, copied },   folder of the last sync (kept over restarts)
      error,                        text of the last failed operation | null
      result,                       text of the last successful one ("N copied, M unchanged", the saved path, ...)
      locked_reason }               null, or why no card command can start now (not connected, update, busy, no page Ld)

Commands (page Ld needed; all but `card_cancel` return `{"ok": true}` at once and run in the background, follow
`busy` / `progress` / `error` / `result`; one at a time, a second one is refused):
`card_list`, `card_info`, `card_download {name, dest}` (dest = folder, default `<recordings folder>/card`; the file is
written as `name.part` and renamed when complete), `card_delete {name}` (cal.bin, EEVBlog.bin, BTLOAD.TMP are refused
before anything is sent), `card_sync {folder}` (new or changed files into the folder; a manifest `.121gw-sync.json` there
records size and date; never deletes local files; BTLOAD.TMP and names that cannot be local files are skipped; folder
omitted = the last one), `card_cancel`.

## state.settings

    { items: [{id, code, name, value, min, max, choices: [names by value] | null, text}],
      locked_reason,                null, or why settings cannot be read / changed now (same reasons as the card)
      error }                       text of the last failed settings command | null

`items` is empty until `settings_get`.  `code` is the SETUP page (`tc dSP bt bL rEL tr CL HUnt bH Ch LP Pt BAT r`, and
`item 0`, `item 2`, `item 3`, `item 4`, `item 10`, `item 11` for the numbered pages of v2.05 that have no letters), `text`
the value in words (`"30 s"`, `"+1.2 %"`, `"Pt100"`).  `value` is within `min..max`; `choices[value]` is the name.  `id`
is the firmware's setting id (EEPROM offset: `tc` 0x00F, temperature unit 0x010, `r` 0x011, `dSP` 0x013, `item 10` 0x014,
`bt` 0x015, `item 2` 0x016, `bL` 0x017 (value 0 off, 1 = 30 s, 2..100 = 1..99 min), `item 4` contrast 0x01A (10..17),
`item 11` 0x01B, `item 3` 0x01E, `bH` 0x021, `Ch` 0x022, `LP` 0x028, `Pt` 0x029, `BAT` 0x02A (value = trim + 100,
50..150)), except the firmware's one id 0x020 (value 0..31: bit 0 REL view, bits 2..1 trigger 0..2, bit 3 clock, bit 4
capacitance anti-hunting, F-1.16 and newer), which is shown as FOUR rows `rEL`, `tr`, `CL`, `HUnt` with the ids 0x120,
0x220, 0x320, 0x420 (`HUnt`: choices off / on; listed and changeable only while the connected firmware is F-1.16 or newer).
A change of one row is a read-modify-write on the host: GET, replace that row's bits, PUT id 0x020 with the whole value,
compare the answer, read back.  If the meter reports an invalid trigger (3) the other rows are refused until `tr` is set.
0x018 (logging interval) is not offered by the meter and not listed.
Commands (synchronous, page Ld needed): `settings_get` -> `{"ok": true, "items": [...]}`; `settings_put {id, value}` ->
the same list after the change was written and read back; a value out of range or an id not listed is a 400 without
anything sent to the meter.

## Notes

- The card and settings byte layouts are those of the firmware (`ble/bftsd.s`, `ble/bftset.s`), defined at the top of
  `card.py` and `settings.py`.  `free_bytes` / `total_bytes` are clusters x sectors per cluster x 512 from INFO.
  `card_list` shows files only: directories, volume labels, names above 63 bytes (the meter cuts them) and sizes of
  4 GiB and above are left out of `files`, and `card_sync` reports them as skipped.  Names the meter does not take
  (anything outside A-Z a-z 0-9 . _ space -, over 63 bytes) cannot be downloaded or deleted from here and are skipped by
  the sync.
- While a card or settings operation runs, status frames are absent and the live view is frozen: the meter shows Ld.
