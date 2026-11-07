# Display pictures for the user manual

Made by `tools/make_screens.py` from the emulator running the production firmware (`firmware/build/EEVBlog.bin`; F-1.06, special_version.png F-1.18) with the synthetic EEPROM; every picture shows the display words the firmware wrote, drawn with the emulator page's glass layers.  Pictures that show the whole front panel (695 x 1338 px) include the dial position and the plugged jacks; the others are cut off below the keys (695 x 665 px).  "main" and "sub" are the decoded text of the main and sub display (the font draws S like 5, b like B, I like 1).  Keys: "long" = held 1 s.  In the edit state of a SETUP page (SETUP held 1 s) the value blinks; an edit picture is made only where the lit phase differs from the normal page, otherwise the normal page picture shows it.  The emulator runs without measurement noise, so every run gives the same readings.

The repository keeps only the pictures the manual uses (src/manual.html), reduced for print to 560 px (display) or
420 px (whole panel) wide with 96 colours; the other pictures listed below are made again by running make_screens.py.

## Dial positions and functions

| File | What it shows | How it was made |
|---|---|---|
| dial_LowZ.png | Dial Low Z, function LowZ - main display "12.0", sub display "25.0c", lit: DC LowZ SegV apo, bar graph 1 segments | dial 1 (Low Z), MODE pressed 0 x; input V 12 V |
| dial_DCV.png | Dial V, function DCV - main display "1.2340", sub display "25.0c", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), MODE pressed 0 x; input V 1.234 V |
| dial_ACV.png | Dial V, function ACV - main display "12.340", sub display "50.00", lit: AC SegV SubHz apo auto, bar graph 7 segments | dial 2 (V), MODE pressed 1 x; input V 12.34 V AC rms 50 Hz |
| dial_ACV_2.png | Dial V, function ACV - main display "12.340", sub display "25.0c", lit: AC AC_DC+ DC SegV apo auto, bar graph 7 segments | dial 2 (V), MODE pressed 2 x; input V 12.34 V AC rms 50 Hz |
| dial_DCmV.png | Dial mV / Temp, function DCmV - main display "123.40", sub display "25.0c", lit: DC SegV SegmV apo auto, bar graph 7 segments | dial 3 (mV / Temp), MODE pressed 0 x; input V 0.1234 V |
| dial_ACmV.png | Dial mV / Temp, function ACmV - main display "100.00", sub display "1.000", lit: AC SegV SegmV SubHz Subk apo auto, bar graph 6 segments | dial 3 (mV / Temp), MODE pressed 1 x; input V 0.1 V AC rms 1000 Hz |
| dial_TEMP.png | Dial mV / Temp, function TEMP - main display "99.9", sub display "23.0c", lit: SegTempC apo | dial 3 (mV / Temp), MODE pressed 2 x; input degC 100 degC, board 23 degC |
| dial_FREQ.png | Dial Hz ms %, function FREQ - main display "1.0000", sub display "23.0c", lit: SegHz Segk apo auto | dial 4 (Hz ms %), MODE pressed 0 x; input Hz 1000 Hz |
| dial_PULSE.png | Dial Hz ms %, function PULSE - main display "0.2000", sub display "23.0c", lit: Subms apo auto | dial 4 (Hz ms %), MODE pressed 1 x; input Hz 1000 Hz, high time 0.0002 s |
| dial_DUTY.png | Dial Hz ms %, function DUTY - main display "25.0", sub display "23.0c", lit: Sub% apo | dial 4 (Hz ms %), MODE pressed 2 x; input Hz 1000 Hz, duty 0.25 |
| dial_OHM.png | Dial Ohm / beep / diode / cap, function OHM - main display "4.7000", sub display "23.0c", lit: SegR Segk apo auto, bar graph 24 segments | dial 5 (Ohm / beep / diode / cap), MODE pressed 0 x; input ohm 4700 ohm |
| dial_BEEP.png | Dial Ohm / beep / diode / cap, function BEEP - main display "10.00", sub display "23.0c", lit: Beep SegR apo, bar graph 1 segments | dial 5 (Ohm / beep / diode / cap), MODE pressed 1 x; input ohm 10 ohm |
| dial_DIODE.png | Dial Ohm / beep / diode / cap, function DIODE - main display "0.6500", sub display "23.0c", lit: Diode SegV apo, bar graph 4 segments | dial 5 (Ohm / beep / diode / cap), MODE pressed 2 x; input diode 0.65 V |
| dial_CAP.png | Dial Ohm / beep / diode / cap, function CAP - main display "100.00", sub display "23.0c", lit: SegCapF Segn apo auto | dial 5 (Ohm / beep / diode / cap), MODE pressed 3 x; input F 1e-07 F |
| dial_DCmVA.png | Dial mVA / VA, function DCmVA, sub display showing the voltage - main display "10.00", sub display "1.0000", lit: DC SegA SegV SegmV SubV apo auto, bar graph 1 segments | dial 6 (mVA / VA), jack mA plugged, MODE pressed 0 x; input VA 1 V and 0.01 A, jack mA plugged |
| dial_DCmVA_current.png | Dial mVA / VA, function DCmVA, sub display showing the current - main display "10.00", sub display "10.000", lit: DC SegA SegV SegmV SubA Subm apo auto, bar graph 1 segments | dial 6 (mVA / VA), jack mA plugged, MODE pressed 0 x; input VA 1 V and 0.01 A, jack mA plugged |
| dial_mVA.png | Dial mVA / VA, function mVA, sub display showing the voltage - main display "10.00", sub display "1.0000", lit: AC SegA SegV SegmV SubV apo auto, bar graph 1 segments | dial 6 (mVA / VA), jack mA plugged, MODE pressed 1 x; input VA 1 V AC rms 50 Hz and 0.01 A, jack mA plugged |
| dial_mVA_current.png | Dial mVA / VA, function mVA, sub display showing the current - main display "10.00", sub display "10.000", lit: AC SegA SegV SegmV SubA Subm apo auto, bar graph 1 segments | dial 6 (mVA / VA), jack mA plugged, MODE pressed 1 x; input VA 1 V AC rms 50 Hz and 0.01 A, jack mA plugged |
| dial_DCVA.png | Dial mVA / VA, function DCVA, sub display showing the voltage - main display "12.00", sub display "12.000", lit: DC SegA SegV SubV apo auto, bar graph 1 segments | dial 6 (mVA / VA), jack A plugged, MODE pressed 0 x; input VA 12 V and 1 A, jack A plugged |
| dial_DCVA_current.png | Dial mVA / VA, function DCVA, sub display showing the current - main display "12.00", sub display "1.000", lit: DC SegA SegV SubA apo auto, bar graph 1 segments | dial 6 (mVA / VA), jack A plugged, MODE pressed 0 x; input VA 12 V and 1 A, jack A plugged |
| dial_VA.png | Dial mVA / VA, function VA, sub display showing the voltage - main display "12.00", sub display "12.000", lit: AC SegA SegV SubV apo auto, bar graph 1 segments | dial 6 (mVA / VA), jack A plugged, MODE pressed 1 x; input VA 12 V AC rms 50 Hz and 1 A, jack A plugged |
| dial_VA_current.png | Dial mVA / VA, function VA, sub display showing the current - main display "12.00", sub display "1.000", lit: AC SegA SegV SubA apo auto, bar graph 1 segments | dial 6 (mVA / VA), jack A plugged, MODE pressed 1 x; input VA 12 V AC rms 50 Hz and 1 A, jack A plugged |
| dial_DCuA.png | Dial uA / uVA, function DCuA - main display "123.40", sub display "BD.0FF", lit: DC SegA Segu apo auto, bar graph 7 segments | dial 7 (uA / uVA), jack mA plugged, MODE pressed 0 x; input A 0.0001234 A, jack mA plugged |
| dial_ACuA.png | Dial uA / uVA, function ACuA - main display "200.00", sub display "BD.0FF", lit: AC SegA Segu apo auto, bar graph 11 segments | dial 7 (uA / uVA), jack mA plugged, MODE pressed 1 x; input A 0.0002 A AC rms 50 Hz, jack mA plugged |
| dial_DCuVA.png | Dial uA / uVA, function DCuVA, sub display showing the voltage - main display "5.0", sub display "0.0500", lit: DC SegA SegV Segu SubV apo auto, bar graph 1 segments | dial 7 (uA / uVA), jack mA plugged, MODE pressed 2 x; input VA 0.05 V and 0.0001 A, jack mA plugged |
| dial_DCuVA_current.png | Dial uA / uVA, function DCuVA, sub display showing the current - main display "5.0", sub display "0.1000", lit: DC SegA SegV Segu SubA Subm apo auto, bar graph 1 segments | dial 7 (uA / uVA), jack mA plugged, MODE pressed 2 x; input VA 0.05 V and 0.0001 A, jack mA plugged |
| dial_uVA.png | Dial uA / uVA, function uVA, sub display showing the voltage - main display "4.9", sub display "0.0499", lit: AC SegA SegV Segu SubV apo auto, bar graph 1 segments | dial 7 (uA / uVA), jack mA plugged, MODE pressed 3 x; input VA 0.05 V AC rms 50 Hz and 0.0001 A, jack mA plugged |
| dial_uVA_current.png | Dial uA / uVA, function uVA, sub display showing the current - main display "4.9", sub display "0.1000", lit: AC SegA SegV Segu SubA Subm apo auto, bar graph 1 segments | dial 7 (uA / uVA), jack mA plugged, MODE pressed 3 x; input VA 0.05 V AC rms 50 Hz and 0.0001 A, jack mA plugged |
| dial_DCmA.png | Dial A / mA, function DCmA - main display "12.340", sub display "BD.0FF", lit: DC SegA SegmV apo auto, bar graph 7 segments | dial 8 (A / mA), jack mA plugged, MODE pressed 0 x; input A 0.01234 A, jack mA plugged |
| dial_ACmA.png | Dial A / mA, function ACmA - main display "20.000", sub display "BD.0FF", lit: AC SegA SegmV apo auto, bar graph 11 segments | dial 8 (A / mA), jack mA plugged, MODE pressed 1 x; input A 0.02 A AC rms 50 Hz, jack mA plugged |
| dial_DCA.png | Dial A / mA, function DCA - main display "1.2340", sub display "BD.0FF", lit: DC SegA apo auto, bar graph 7 segments | dial 8 (A / mA), jack A plugged, MODE pressed 0 x; input A 1.234 A, jack A plugged |
| dial_ACA.png | Dial A / mA, function ACA - main display "1.5000", sub display "BD.0FF", lit: AC SegA apo auto, bar graph 8 segments | dial 8 (A / mA), jack A plugged, MODE pressed 1 x; input A 1.5 A AC rms 50 Hz, jack A plugged |

## Function states

| File | What it shows | How it was made |
|---|---|---|
| func_hold.png | HOLD: the reading is frozen - main display "1.0000", sub display "25.0c", lit: DC HOLD SegV apo, bar graph 6 segments | dial 2 (V), DCV; input V 1 V; HOLD pressed once |
| func_autohold.png | AutoHOLD: the A- symbol and HOLD are lit - main display "1.0000", sub display "25.0c", lit: A- DC HOLD SegV apo auto, bar graph 6 segments | dial 2 (V), DCV; input V 1 V; HOLD pressed twice |
| func_rel.png | REL: the reading relative to the value when REL was pressed (1.5 V - 1.0 V) - main display "0.5000", sub display "25.0c", lit: DC REL SegV apo, bar graph 8 segments | DCV; input 1.0 V, REL pressed, input then raised to V 1.5 V |
| func_max.png | MIN/MAX mode, MAX shown (MIN/MAX pressed 1 x) - main display "2.0000", sub display "n  82", lit: DC MAX SegV, bar graph 7 segments | DCV; input 1.0 V, MIN/MAX pressed, input then 2.0 V, then 0.5 V, then V 1.234 V; MIN/MAX pressed 1 x in all |
| func_min.png | MIN/MAX mode, MIN shown (MIN/MAX pressed 2 x) - main display "0.5000", sub display "n  97", lit: DC MIN SegV, bar graph 7 segments | DCV; input 1.0 V, MIN/MAX pressed, input then 2.0 V, then 0.5 V, then V 1.234 V; MIN/MAX pressed 2 x in all |
| func_avg.png | MIN/MAX mode, AVG shown (MIN/MAX pressed 3 x) - main display "1.2330", sub display "n 112", lit: AVG DC SegV, bar graph 7 segments | DCV; input 1.0 V, MIN/MAX pressed, input then 2.0 V, then 0.5 V, then V 1.234 V; MIN/MAX pressed 3 x in all |
| func_minmax_all.png | MIN/MAX mode, MAX MIN AVG shown (MIN/MAX pressed 4 x) - main display "1.2340", sub display "n 127", lit: AVG DC MAX MIN SegV, bar graph 7 segments | DCV; input 1.0 V, MIN/MAX pressed, input then 2.0 V, then 0.5 V, then V 1.234 V; MIN/MAX pressed 4 x in all |
| func_bargraph.png | Bar graph at 3.0 V of the 5 V range (about 60 %) - main display "3.0000", sub display "25.0c", lit: DC SegV apo auto, bar graph 16 segments | DCV; input V 3 V |
| func_range_auto.png | Auto range: the AUTO symbol is lit - main display "1.2340", sub display "25.0c", lit: DC SegV apo auto, bar graph 7 segments | DCV; input 1.234 V; nothing pressed |
| func_range_manual.png | Manual range (RANGE pressed once): the AUTO symbol is off - main display "1.2340", sub display "25.0c", lit: DC SegV apo, bar graph 7 segments | DCV; input 1.234 V; RANGE pressed once |
| func_highvoltage.png | High-voltage symbol (Shock) lit at 650 V - main display "650.0", sub display "25.0c", lit: DC SegV Shock apo auto, bar graph 17 segments | DCV; input V 650 V |
| func_ofl_mv.png | Overload on the mV range - main display "0F.L", sub display "25.0c", lit: DC SegV SegmV apo auto, bar graph 26 segments | dial 3 (mV), DCmV; input V 0.7 V |
| func_ofl_ohm.png | Ohm, test leads open: overload - main display "0.FL", sub display "25.0c", lit: SegM SegR apo auto, bar graph 26 segments | dial 5 (Ohm), OHM; input open |
| func_peak.png | PEAK in ACV (symbol MAX, sub display in ms): the state is the firmware's; the value is not representative, the emulator does not derive the peak converter (AD2) from the input - main display "3.125", sub display "50.00", lit: AC MAX SegV Sub1 SubHz Subms apo, bar graph 2 segments | dial 2 (V), ACV; input V 12.34 V AC rms 50 Hz; PEAK pressed |
| func_filter.png | The 1 kHz filter is on in ACV - main display "12.340", sub display "50.00", lit: 1 kHz AC SegV SubHz apo auto, bar graph 7 segments | dial 2 (V), ACV; input V 12.34 V AC rms 50 Hz; REL held 1 s |
| func_bluetooth.png | Bluetooth is on: the bt symbol is lit - main display "1.2340", sub display "25.0c", lit: DC SegV apo auto bt, bar graph 7 segments | DCV; input 1.234 V; PEAK held 1 s |
| func_logging.png | Logging to the SD card is running (MEM symbol) - main display "1.2340", sub display "5", lit: DC MEM SegV, bar graph 7 segments | DCV; input 1.234 V; SD card (FAT32 image) inserted; logging interval 1 s; MEM held 1 s, 4 s later |

## SETUP pages common to all functions (DCV)

| File | What it shows | How it was made |
|---|---|---|
| setup_00_25_0c.png | SETUP page 25.0c (item 0) - main display "1.2340", sub display "25.0c", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 0 x |
| setup_01_BAT6_0.png | SETUP page BAT6.0 (item 1) - main display "1.2340", sub display "BAT6.0", lit: DC SegV SubV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 1 x |
| setup_01_BAT6_0_edit.png | Edit state of page BAT6.0: the value changes look and blinks (the picture shows the phase with the value lit) - main display "1.2340", sub display "BA6.00", lit: DC SegV SubV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 1 x, then held 1 s |
| setup_02_AP0_30.png | SETUP page AP0.30 (item 2, F-1.18) - main display "1.2340", sub display "AP0.30", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 2 x |
| setup_03_B_0n.png | SETUP page B-0n (item 3) - main display "1.2340", sub display "B-0n", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 3 x |
| setup_04_LcD_4.png | SETUP page LcD-4 (item 4) - main display "1.2340", sub display "LcD-4", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 4 x |
| setup_05_2026.png | SETUP page 2026 (item 5) - main display "1.2340", sub display "2026", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 5 x |
| setup_06_11_05.png | SETUP page 11-05 (item 6) - main display "1.2340", sub display "11-05", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 6 x |
| setup_07_02_10.png | SETUP page 02-10 (item 7) - main display "1.2340", sub display "02-10", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 7 x |
| setup_08_00000.png | SETUP page 00000 (item 8) - main display "1.2340", sub display "00000", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 8 x |
| setup_09_1n__0.png | SETUP page 1n  0 (item 9) - main display "1.2340", sub display "1n  0", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 9 x |
| setup_20_BL0FF.png | SETUP page BL0FF (item 20) - main display "1.2340", sub display "BL0FF", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 10 x |
| setup_21_BT__2.png | SETUP page BT  2 (item 21) - main display "1.2340", sub display "BT  2", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 11 x |
| setup_39_LD_BT.png | SETUP page LD-BT (item 39) - main display "1.2340", sub display "LD-BT", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 12 x |
| setup_22_rEL_D.png | SETUP page rEL-D (item 22) - main display "1.2340", sub display "rEL-D", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 13 x |
| setup_24_D5P_1.png | SETUP page D5P 1 (item 24) - main display "1.2340", sub display "D5P 1", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 14 x |
| setup_25_CL_24.png | SETUP page CL 24 (item 25) - main display "1.2340", sub display "CL 24", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 15 x |
| setup_27_LT0FF.png | SETUP page LT0FF (item 27) - main display "1.2340", sub display "LT0FF", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 16 x |
| setup_28_Lo.png | SETUP page Lo--- (item 28) - main display "1.2340", sub display "Lo---", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 17 x |
| setup_29_H1.png | SETUP page H1--- (item 29) - main display "1.2340", sub display "H1---", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 18 x |
| setup_30_Tr_1n.png | SETUP page Tr-1n (item 30) - main display "1.2340", sub display "Tr-1n", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; SETUP pressed 19 x |
| setup_32_n__43.png | SETUP page n  43 (item 32) - main display "1.2340", sub display "n  43", lit: DC MAX SegV, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; MIN/MAX pressed once; SETUP pressed 0 x |
| setup_33_5D.png | SETUP page 5D (item 33) - main display "0.0000", sub display "5D", lit: DC MAX SegV, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; MIN/MAX pressed once; SETUP pressed 1 x |
| setup_34_TH1.png | SETUP page TH1 (item 34) - main display "02-11", sub display "TH1", lit: DC MAX SegV, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; MIN/MAX pressed once; SETUP pressed 2 x |
| setup_35_TLo.png | SETUP page TLo (item 35) - main display "02-11", sub display "TLo", lit: DC MAX SegV, bar graph 7 segments | dial 2 (V), DCV; input V 1.234 V; MIN/MAX pressed once; SETUP pressed 3 x |

Not made:

- setup_08_00000_edit: the edit of the ID page (item 8) is left only by saving the serial number or after 2 minutes

## SETUP pages of Low Z, V and mV / Temp that differ from DCV

| File | What it shows | How it was made |
|---|---|---|
| setup_ACV_10_50_00.png | SETUP page 50.00 (item 10) - main display "12.340", sub display "50.00", lit: AC SegV SubHz apo auto, bar graph 7 segments | dial 2 (V), MODE pressed 1 x; input V 12.34 V AC rms 50 Hz; SETUP pressed 0 x |
| setup_ACV_11_24_04.png | SETUP page 24.04 (item 11) - main display "12.340", sub display "24.04", lit: AC SegV SubdB Subm apo auto, bar graph 7 segments | dial 2 (V), MODE pressed 1 x; input V 12.34 V AC rms 50 Hz; SETUP pressed 1 x |
| setup_ACV_11_24_04_edit.png | Edit state of page 24.04: the value changes look and blinks (the picture shows the phase with the value lit) - main display "12.340", sub display "r 600", lit: AC SegV SubdB Subm apo auto, bar graph 7 segments | dial 2 (V), MODE pressed 1 x; input V 12.34 V AC rms 50 Hz; SETUP pressed 1 x, then held 1 s |
| setup_ACmV_10_1_000.png | SETUP page 1.000 (item 10) - main display "100.00", sub display "1.000", lit: AC SegV SegmV SubHz Subk apo auto, bar graph 6 segments | dial 3 (mV / Temp), MODE pressed 1 x; input V 0.1 V AC rms 1000 Hz; SETUP pressed 0 x |
| setup_TEMP_00_23_0c.png | SETUP page 23.0c (item 0) - main display "99.9", sub display "23.0c", lit: SegTempC apo | dial 3 (mV / Temp), MODE pressed 2 x; input degC 100 degC, board 23 degC; SETUP pressed 0 x |
| setup_TEMP_23_Tc_K.png | SETUP page Tc-K (item 23) - main display "99.9", sub display "Tc-K", lit: SegTempC apo | dial 3 (mV / Temp), MODE pressed 2 x; input degC 100 degC, board 23 degC; SETUP pressed 14 x |

## SETUP pages of Hz and Ohm / beep / diode / cap that differ from DCV

| File | What it shows | How it was made |
|---|---|---|
| setup_OHM_38_PT0FF.png | SETUP page PT0FF (item 38) - main display "4.7000", sub display "PT0FF", lit: SegR Segk apo auto, bar graph 24 segments | dial 5 (Ohm / beep / diode / cap), MODE pressed 0 x; input ohm 4700 ohm; SETUP pressed 15 x |
| setup_BEEP_10_DN_30.png | SETUP page DN 30 (item 10) - main display "10.00", sub display "DN 30", lit: Beep SegR SubR apo, bar graph 1 segments | dial 5 (Ohm / beep / diode / cap), MODE pressed 1 x; input ohm 10 ohm; SETUP pressed 10 x |
| setup_BEEP_26_BH100.png | SETUP page BH100 (item 26) - main display "10.00", sub display "BH100", lit: Beep SegR apo, bar graph 1 segments | dial 5 (Ohm / beep / diode / cap), MODE pressed 1 x; input ohm 10 ohm; SETUP pressed 16 x |
| setup_DIODE_10_3.png | SETUP page 3 (item 10) - main display "0.6500", sub display "3", lit: Diode SegV SubV apo, bar graph 4 segments | dial 5 (Ohm / beep / diode / cap), MODE pressed 2 x; input diode 0.65 V; SETUP pressed 10 x |

## SETUP pages of mVA / VA and uA / uVA that differ from DCV

| File | What it shows | How it was made |
|---|---|---|
| setup_DCmVA_10_10_000.png | SETUP page 10.000 (item 10) - main display "10.00", sub display "10.000", lit: DC SegA SegV SegmV SubA Subm apo auto, bar graph 1 segments | dial 6 (mVA / VA), jack mA plugged, MODE pressed 0 x; input VA 1 V and 0.01 A, jack mA plugged; SETUP pressed 0 x |
| setup_DCmVA_11_BD_0FF.png | SETUP page BD.0FF (item 11) - main display "10.00", sub display "BD.0FF", lit: DC SegA SegV SegmV apo auto, bar graph 1 segments | dial 6 (mVA / VA), jack mA plugged, MODE pressed 0 x; input VA 1 V and 0.01 A, jack mA plugged; SETUP pressed 1 x |
| setup_DCVA_10_12_000.png | SETUP page 12.000 (item 10) - main display "12.00", sub display "12.000", lit: DC SegA SegV SubV apo auto, bar graph 1 segments | dial 6 (mVA / VA), jack A plugged, MODE pressed 0 x; input VA 12 V and 1 A, jack A plugged; SETUP pressed 0 x |
| setup_VA_10_1_000.png | SETUP page 1.000 (item 10) - main display "12.00", sub display "1.000", lit: AC SegA SegV SubA apo auto, bar graph 1 segments | dial 6 (mVA / VA), jack A plugged, MODE pressed 1 x; input VA 12 V AC rms 50 Hz and 1 A, jack A plugged; SETUP pressed 0 x |
| setup_DCuA_10_BD_0FF.png | SETUP page BD.0FF (item 10) - main display "123.40", sub display "BD.0FF", lit: DC SegA Segu apo auto, bar graph 7 segments | dial 7 (uA / uVA), jack mA plugged, MODE pressed 0 x; input A 0.0001234 A, jack mA plugged; SETUP pressed 0 x |
| setup_ACuA_11_50_00.png | SETUP page 50.00 (item 11) - main display "200.00", sub display "50.00", lit: AC SegA Segu SubHz apo auto, bar graph 11 segments | dial 7 (uA / uVA), jack mA plugged, MODE pressed 1 x; input A 0.0002 A AC rms 50 Hz, jack mA plugged; SETUP pressed 1 x |
| setup_DCuVA_10_0_1000.png | SETUP page 0.1000 (item 10) - main display "5.0", sub display "0.1000", lit: DC SegA SegV Segu SubA Subm apo auto, bar graph 1 segments | dial 7 (uA / uVA), jack mA plugged, MODE pressed 2 x; input VA 0.05 V and 0.0001 A, jack mA plugged; SETUP pressed 0 x |

## SETUP pages of A / mA that differ from DCV

| File | What it shows | How it was made |
|---|---|---|
| setup_DCmA_10_BD_0FF.png | SETUP page BD.0FF (item 10) - main display "12.340", sub display "BD.0FF", lit: DC SegA SegmV apo auto, bar graph 7 segments | dial 8 (A / mA), jack mA plugged, MODE pressed 0 x; input A 0.01234 A, jack mA plugged; SETUP pressed 0 x |
| setup_DCmA_37_LP0FF.png | SETUP page LP0FF (item 37) - main display "12.340", sub display "LP0FF", lit: DC SegA SegmV apo auto, bar graph 7 segments | dial 8 (A / mA), jack mA plugged, MODE pressed 0 x; input A 0.01234 A, jack mA plugged; SETUP pressed 6 x |
| setup_ACmA_11_50_00.png | SETUP page 50.00 (item 11) - main display "20.000", sub display "50.00", lit: AC SegA SegmV SubHz apo auto, bar graph 11 segments | dial 8 (A / mA), jack mA plugged, MODE pressed 1 x; input A 0.02 A AC rms 50 Hz, jack mA plugged; SETUP pressed 1 x |

## Special screens

| File | What it shows | How it was made |
|---|---|---|
| special_version.png | Power-on: the firmware version on the sub display (the main display is still blank) - main display "", sub display "F-1.18", bar graph 1 segments | dial 2 (V); power cycle, display after 0.10 s |
| special_lamptest.png | Lamp test of the power-on window: every segment on | power cycle, RANGE pressed 0.5 s later and held |
| msg_oFF.png | Power-off screen "-oFF-" (auto power-off, shown for the last beep) - main display "-oFF-", sub display "" | dial 2 (V); auto power-off countdown (RAM 0x20000230) set to 2 s and run out |
| msg_SdCAL.png | cal.bin menu "SdCAL" (MEM held at power-on) - main display "5D.CAL", sub display "" | power cycle with MEM held, released after 0.5 s |
| msg_SdSAv.png | cal.bin: save chosen, "SdSAv" - main display "5D.5Au", sub display "" | as msg_SdCAL, then REL pressed |
| msg_SAvEd.png | cal.bin written to the card: "SAvEd" - main display "5AuED", sub display "" | as msg_SdSAv, then MODE pressed (card: empty FAT32 image) |
| msg_SdSEt.png | cal.bin: load chosen, "SdSEt" - main display "5D.5ET", sub display "" | as msg_SdCAL, then PEAK pressed |
| msg_Err.png | cal.bin could not be loaded (no CAL.BIN on the card): "-Err-" - main display "-Err-", sub display "" | power cycle with MEM held, PEAK, MODE; card: empty FAT32 image |
| special_battery.png | Low-battery symbol (battery voltage 3.8 V) - main display "1.2340", sub display "25.0c", lit: Battery DC SegV apo auto, bar graph 7 segments | DCV; input 1.234 V; battery set to 3.8 V |
| msg_LoBAt.png | Logging refused because the battery is low: "LoBAt" - main display "1.2340", sub display "LoB.AT", lit: Battery DC SegV auto, bar graph 7 segments | DCV; battery set to 3.8 V; MEM held 1 s |
| msg_SdE03.png | SD error "SdE 03": logging started with no card in the socket - main display "1.2340", sub display "5DE.03", lit: DC SegV apo auto, bar graph 7 segments | DCV; no SD card image; MEM held 1 s, display 2 s later |
| msg_LEAD.png | Wrong current jack: the uA position with the A jack plugged shows LEAD - main display "LEAD", sub display "BD.0FF", lit: DC SegA Segu apo auto, bar graph 1 segments | dial 7 (uA / uVA), jack A plugged |

Not made:

- msg_SdExx: no SdE message (logging started with a card that has no file system (64 MiB of zeros)): main "1.2340", sub " 25.0c"

## Limit test and logging trigger pages

| File | What it shows | How it was made |
|---|---|---|
| limit_lo_page.png | Limit test, page of the low limit, nothing captured yet - main display "99.00", sub display "Lo---", lit: SegR apo auto, bar graph 5 segments | dial 5 (Ohm), OHM; input 99 ohm; SETUP pressed up to the page |
| limit_lo_edit.png | Limit test, edit of the low limit page after REL (the reading 99 ohm is captured) - main display "99.00", sub display "Lo", lit: SegR apo auto, bar graph 5 segments | dial 5 (Ohm), OHM; input 99 ohm; the page, SETUP held 1 s, REL pressed |
| limit_hi_page.png | Limit test, page of the high limit, nothing captured yet - main display "101.00", sub display "H1---", lit: SegR apo auto, bar graph 6 segments | dial 5 (Ohm), OHM; input 101 ohm; SETUP pressed up to the page |
| limit_hi_edit.png | Limit test, edit of the high limit page after REL (the reading 101 ohm is captured) - main display "101.00", sub display "H1", lit: SegR apo auto, bar graph 6 segments | dial 5 (Ohm), OHM; input 101 ohm; the page, SETUP held 1 s, REL pressed |
| limit_lt_page.png | Limit test page Lt, test off - main display "101.00", sub display "LT0FF", lit: SegR apo auto, bar graph 6 segments | dial 5 (Ohm), OHM; limits 99 and 101 ohm captured; SETUP pressed up to the page |
| limit_lt_edit.png | Limit test page Lt in edit after REL: "LtOn" (test on) - main display "101.00", sub display "LT0n", lit: SegR apo, bar graph 6 segments | dial 5 (Ohm), OHM; the page, SETUP held 1 s, REL pressed |
| limit_verdict_pass.png | Limit test verdict PASS: inside the limits (input 100 ohm, limits 99 and 101 ohm) - main display "100.00", sub display "PA55", lit: SegR apo, bar graph 6 segments | dial 5 (Ohm), OHM; limits captured, Lt on; input 100 ohm |
| limit_verdict_hi.png | Limit test verdict HI: above the high limit (input 150 ohm, limits 99 and 101 ohm) - main display "150.00", sub display "H1", lit: SegR apo, bar graph 8 segments | dial 5 (Ohm), OHM; limits captured, Lt on; input 150 ohm |
| limit_verdict_lo.png | Limit test verdict Lo: below the low limit (input 50 ohm, limits 99 and 101 ohm) - main display "50.00", sub display "Lo", lit: SegR apo, bar graph 3 segments | dial 5 (Ohm), OHM; limits captured, Lt on; input 50 ohm |
| trig_tr_page.png | Logging trigger page tr, the default "tr-In" (a record every interval) - main display "1.2340", sub display "Tr-1n", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input 1.234 V; SETUP pressed up to the page |
| trig_tr_edit_ch.png | Page tr in edit after REL: "tr-Ch" (a record when the reading changes by the threshold) - main display "1.2340", sub display "Tr-Ch", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input 1.234 V; the page, SETUP held 1 s, REL pressed |
| trig_tr_edit_lt.png | Page tr in edit after REL twice: "tr-Lt" (a record when the limit test verdict changes) - main display "1.2340", sub display "Tr-LT", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input 1.234 V; the page, SETUP held 1 s, REL pressed twice |
| trig_ch_page.png | Logging trigger page Ch (the change threshold, offered with tr-Ch) - main display "1.2340", sub display "Ch  1", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input 1.234 V; tr set to tr-Ch and saved; SETUP pressed once more |
| trig_ch_edit.png | Page Ch in edit after REL: the threshold changed by one step - main display "1.2340", sub display "Ch  2", lit: DC SegV apo auto, bar graph 7 segments | dial 2 (V), DCV; input 1.234 V; the page, SETUP held 1 s, REL pressed |

## Bootloader screens

| File | What it shows | How it was made |
|---|---|---|
| boot_lamptest.png | Power-on lamp test of the two-part bootloader: every segment on | flash image with starter, bootloader and firmware, power-on with no key held |
| boot_iap.png | Bootloader update mode (no valid firmware): "-IAP-" on both displays, Bluetooth on - main display "-1AP-", sub display "-1AP-" | flash image whose firmware mark is erased, power-on with no key held |
| boot_ld_nn.png | Bootloader receiving the firmware over Bluetooth: "Ld nn" (progress in percent) with the bar graph - main display "LD 50", sub display "-1AP-", bar graph 12 segments | update mode (-IAP-), firmware image sent over the Bluetooth link; the picture is the sample nearest 50 % |
| boot_ld_ok.png | Bootloader: the firmware is received and written: "Ld oK" - main display "LD oK", sub display "-1AP-", bar graph 26 segments | as boot_ld_nn, after the last packet |
| boot_card_menu.png | Bootloader update mode with the card (MEM + HOLD at power-on) - main display "-1AP-", sub display "-1AP-" | MEM and HOLD held through the power-on, released after 1 s; EEVBlog.bin on the card |
| boot_card_progress.png | Bootloader programming from the card: "douun" with the bar graph (the picture is the fullest bar graph) - main display "Douun", sub display "-1AP-", bar graph 25 segments | as boot_card_menu, then SETUP pressed |
| boot_card_good.png | Bootloader: card update done, " Good" - main display "9ooD", sub display "-1AP-", bar graph 25 segments | as boot_card_menu, then SETUP pressed |

## Firmware pages that need the two-part bootloader

| File | What it shows | How it was made |
|---|---|---|
| ld_bt.png | SETUP page Ld-bt: the card file transfer over Bluetooth is ready - main display "0.0000", sub display "LD-BT", lit: DC SegV apo auto bt, bar graph 1 segments | DCV, Bluetooth on (PEAK held 1 s); SETUP pressed until page Ld |
| ld_nn.png | Page Ld during a file transfer from the companion: "Ld nn" (progress in percent) - main display "0.0000", sub display "LD 50", lit: DC SegV apo auto bt, bar graph 1 segments | as ld_bt; the firmware image sent over Bluetooth, the sample nearest 50 % |
| ld_ok.png | Page Ld: the file arrived and was checked: "Ld oK" - main display "0.0000", sub display "LD oK", lit: DC SegV apo auto bt, bar graph 1 segments | as ld_nn, after the last packet |
| for_page.png | SETUP page For (format the card as exFAT), the question "Fr no" - main display "0.0000", sub display "Fr no", lit: DC SegV apo auto, bar graph 1 segments | DCV; SETUP pressed until page For (after Ld-bt) |
| for_edit_yes.png | Page For in edit after REL: the answer "Fr yE" (yes) - main display "0.0000", sub display "Fr YE", lit: DC SegV apo auto, bar graph 1 segments | as for_page, SETUP held 1 s, REL pressed |
| for_working.png | Page For while the card is being formatted: "Fr --" - main display "0.0000", sub display "Fr --", lit: DC SegV apo auto, bar graph 1 segments | as for_edit_yes, then SETUP held 1 s to confirm |
| for_ok.png | Page For: the card is now exFAT: "Fr oK" - main display "0.0000", sub display "Fr oK", lit: DC SegV apo auto, bar graph 1 segments | as for_edit_yes, then SETUP held 1 s to confirm |

## Features of the open firmware in use

| File | What it shows | How it was made |
|---|---|---|
| feat_relpct.png | REL in percent: reference 1.000 V, now 1.100 V - main display "10.000", sub display "25.0c", lit: DC REL Sub% apo, bar graph 6 segments | dial 2 DCV, rEL-P preset (0x020 = 1); 1.0 V, REL, then 1.1 V |
| feat_dbm.png | dBm of 1.000 V AC (600 ohm reference) - main display "1.0000", sub display "2.218", lit: AC SegV SubdB Subm apo auto, bar graph 6 segments | dial 2 ACV, 1.0 V AC 1 kHz, SETUP to the dBm page (11) |
| feat_dbm_ref.png | dBm reference page in edit: r 600 - main display "1.0000", sub display "r 600", lit: AC SegV SubdB Subm apo auto, bar graph 6 segments | as feat_dbm, SETUP held: reference edit |
| feat_loop.png | 4-20 mA loop view: 12 mA shown as 50 % - main display "50.00", sub display "BD.0FF", lit: DC Sub% apo auto, bar graph 7 segments | dial 8 DCmA, mA jack, L4-20 preset (0x028 = 1), 12 mA |
| feat_pt100.png | PT100 view: 138.51 ohm shown as a temperature - main display "100.0", sub display "25.0c", lit: SegTempC apo auto, bar graph 7 segments | dial 5 OHM, Pt100 preset (0x029 = 1), 138.51 ohm |
| feat_up300.png | Continuity threshold UP300 (beep above 300 ohm) - main display "0F.L", sub display "UP300", lit: Beep SegR SubR apo, bar graph 26 segments | dial 5 BEEP, 0x014 = 3, SETUP to page 10 |
| feat_bh25.png | Continuity beep hold 25 ms - main display "0F.L", sub display "BH 25", lit: Beep SegR apo, bar graph 26 segments | dial 5 BEEP, 0x021 = 2, SETUP to the bH page |
| feat_tcJ.png | Thermocouple type J selected - main display "82.9", sub display "Tc-J", lit: SegTempC apo | dial 3 TEMP, 0x00F = 1, SETUP to the tc page |
| feat_hunt.png | Capacitance anti-hunting on: the page HUnt - main display "on", sub display "HUnT", lit: SegCapF Segn apo auto | dial 5 CAP, HUnt preset (0x020 = 0x10), 100 nF, SETUP to the page HUnt (item 41) |
| feat_dsp2.png | Display level 2 - main display "1.2340", sub display "D5P 2", lit: DC SegV apo auto, bar graph 7 segments | dial 2 DCV; preset 0x013 = 1, 0x015 = 3, 0x020 = 8, 0x017 = 1; SETUP to page 24 |
| feat_bt20.png | Bluetooth 20 readings per second - main display "1.2340", sub display "BT 20", lit: DC SegV apo auto, bar graph 7 segments | dial 2 DCV; preset 0x013 = 1, 0x015 = 3, 0x020 = 8, 0x017 = 1; SETUP to page 21 |
| feat_cl12.png | 12-hour clock display - main display "1.2340", sub display "CL 12", lit: DC SegV apo auto, bar graph 7 segments | dial 2 DCV; preset 0x013 = 1, 0x015 = 3, 0x020 = 8, 0x017 = 1; SETUP to page 25 |
| feat_bl30.png | Backlight off after 30 s - main display "1.2340", sub display "BL305", lit: DC SegV apo auto, bar graph 7 segments | dial 2 DCV; preset 0x013 = 1, 0x015 = 3, 0x020 = 8, 0x017 = 1; SETUP to page 20 |
| feat_time12.png | Time page in 12-hour form - main display "1.2340", sub display "6-25", lit: DC SegV apo auto, bar graph 7 segments | dial 2 DCV; preset 0x013 = 1, 0x015 = 3, 0x020 = 8, 0x017 = 1; SETUP to page 7 |

## Display crops of the dial pictures

Cut from the full-panel dial pictures for the picture grid of the manual.

| File | What it shows | How it was made |
|---|---|---|
| d_DCV.png | The display part of dial_DCV.png | top 665 of 1338 px of dial_DCV.png (the panel above the dial) |
| d_ACV.png | The display part of dial_ACV.png | top 665 of 1338 px of dial_ACV.png (the panel above the dial) |
| d_LowZ.png | The display part of dial_LowZ.png | top 665 of 1338 px of dial_LowZ.png (the panel above the dial) |
| d_TEMP.png | The display part of dial_TEMP.png | top 665 of 1338 px of dial_TEMP.png (the panel above the dial) |
| d_FREQ.png | The display part of dial_FREQ.png | top 665 of 1338 px of dial_FREQ.png (the panel above the dial) |
| d_OHM.png | The display part of dial_OHM.png | top 665 of 1338 px of dial_OHM.png (the panel above the dial) |
| d_DCmA.png | The display part of dial_DCmA.png | top 665 of 1338 px of dial_DCmA.png (the panel above the dial) |
