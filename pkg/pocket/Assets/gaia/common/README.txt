Gaiapolis for Analogue Pocket - the ROM image
====================================================

This folder must hold ONE file:

    Assets/gaia/common/gaia.rom
    (1,511,424 bytes, md5 8d6ae2b1177b78d2fdcda8956d492f72)

The core does not include any game data. You build gaia.rom yourself from
your own copy of the MAME romset "gaia" (S.T.U.N. Runner, Atari Games 1989;
the MAME parent set, gaia.zip).

How to build it
---------------
1. Put gaia.zip next to the two files at the top of this release:
   gaia.mra (the recipe) and mra_build.py (the builder).

2. Run, with any Python 3 -- nothing else to install:

       python3 mra_build.py gaia.mra gaia.zip

   It checks every ROM's CRC32 against the .mra, writes gaia.rom, and
   verifies the finished image against the md5 above. A wrong or incomplete
   romset stops with an error naming the file it did not like.

3. Copy gaia.rom into this folder on the SD card.

The .mra is a standard MiSTer-style ROM description, so any MRA tool (for
example the MiSTer project's "mra") builds the same image; rename its output
to gaia.rom.

What the image contains (docs/hardware.md, section 8, in the repository)
------------------------------------------------------------------------
    0x000000   786,432  68010 program (big-endian words)
    0x0C0000   393,216  ADSP-2100 serial "SIM" data
    0x120000   262,144  OKI6295 ADPCM samples
    0x160000    65,536  JSA II 6502 program
    0x170000     2,048  timekeeper NVRAM factory contents
    0x170800     2,048  EEPROM factory contents
