Gaiapolis for Analogue Pocket - the ROM image
=============================================

This folder must hold ONE file:

    Assets/gaia/common/gaiapolis.rom
    (20,316,288 bytes, md5 7ed05d08287ecc2be8592b0ef0158aad)

The core does not include any game data. You build gaiapolis.rom yourself
from your own copy of the MAME romset "gaiapols" (Gaiapolis, Konami 1993,
ver EAF; the MAME parent set, gaiapols.zip).

How to build it
---------------
1. Put gaiapols.zip next to the two files at the top of this release:
   gaiapolis.mra (the recipe) and mra_build.py (the builder).

2. Run, with any Python 3 -- nothing else to install:

       python3 mra_build.py gaiapolis.mra gaiapols.zip

   It checks every ROM's CRC32 against the .mra, writes gaiapolis.rom, and
   verifies the finished image against the md5 above. A wrong or incomplete
   romset stops with an error naming the file it did not like.

3. Copy gaiapolis.rom into this folder on the SD card.

The .mra is a standard MiSTer-style ROM description, so any MRA tool (for
example the MiSTer project's "mra") builds the same image; rename its output
to gaiapolis.rom.

What the image contains (docs/hardware.md, section 9, in the repository)
------------------------------------------------------------------------
    0x0000000  3,145,728  68000 program (big-endian words)
    0x0300000    262,144  Z80 sound program
    0x0340000  2,097,152  K056832 tiles
    0x0540000  1,572,864  K053936 ROZ characters
    0x06C0000    655,360  K053936 ROZ map
    0x0760000  4,194,304  K054539 PCM samples
    0x0B60000  8,388,608  K053247 sprites
    0x1360000        128  EEPROM factory contents
