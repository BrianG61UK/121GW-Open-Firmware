# Changelog of the two-part bootloader

What each release (tags bl-vA.B.C) brought, newest first. The release page of a version shows only its own paragraphs.

New in bl-v1.1.4 (B-1.14): after an update over Bluetooth the meter starts with Bluetooth on, so the 121GW Companion reconnects and confirms the update without a key press (GitHub issue 23; needs firmware v1.2.2 or newer, which reads the note the bootloader leaves; bootloader DESIGN.md 6.5.1). The update that installs this bootloader is done by the older one, so after that one update hold PEAK once. Verified working on a meter (B-1.14 installed over Bluetooth by B-1.13, then a firmware update over Bluetooth came back with Bluetooth on).

New in bl-v1.1.3 (B-1.13): the card update reads the SD card at the firmware's card-session clock (32 MHz, as the processor's reference manual requires for the SD interface; firmware v1.1.2, GitHub issue 5) instead of 4 MHz.
