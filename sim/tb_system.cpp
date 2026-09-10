// Full-system bench: the whole machine from reset, real program ROM, video
// out. Runs N frames, writes the last frame as RGB and a PNG-able dump, and
// reports what the 68000 did: steps, IRQ5 count per frame, the PC histogram
// of the last frame, and the diagnostics flags.
//
//   tb_system <gaiapolis.rom> <frames> <out.rgb> [trace.txt]
#include "Vtb_system_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <map>
#include <algorithm>

static const int VIS_W = 376, VIS_H = 224;
static const long ROM_MAINCPU = 0x0000000, MAINCPU_LEN = 0x300000;
static const long ROM_TILES = 0x0340000, TILES_LEN = 0x200000;
static const long ROM_ROZCHAR = 0x0540000, ROZCHAR_LEN = 0x180000;
static const long ROM_ROZMAP = 0x06C0000, ROZMAP_LEN = 0x0A0000;
static const long ROM_SPRITES = 0x0B60000, SPRITES_LEN = 0x800000;
static const long ROM_EEPROM = 0x1360000, EEPROM_LEN = 0x80;

static Vtb_system_top *dut;
static unsigned long long cycles = 0;
static inline void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cycles++; }

static std::vector<unsigned char> region(FILE *rf, long off, long len, const char *what) {
    std::vector<unsigned char> d(len);
    fseek(rf, off, SEEK_SET);
    if (fread(d.data(), 1, len, rf) != (size_t)len) { fprintf(stderr, "short read of %s\n", what); exit(1); }
    return d;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: %s <rom> <frames> <out.rgb> [trace.txt]\n", argv[0]); return 2; }
    int frames = atoi(argv[2]);
    FILE *tr = argc > 4 ? fopen(argv[4], "w") : nullptr;

    FILE *rf = fopen(argv[1], "rb");
    if (!rf) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
    auto prog = region(rf, ROM_MAINCPU, MAINCPU_LEN, "program");
    auto tiles = region(rf, ROM_TILES, TILES_LEN, "tiles");
    auto rchr = region(rf, ROM_ROZCHAR, ROZCHAR_LEN, "gfx3");
    auto rmap = region(rf, ROM_ROZMAP, ROZMAP_LEN, "gfx4");
    auto spr = region(rf, ROM_SPRITES, SPRITES_LEN, "sprites");
    auto eep = region(rf, ROM_EEPROM, EEPROM_LEN, "eeprom");
    fclose(rf);

    dut = new Vtb_system_top;
    dut->reset = 1;
    dut->in0_p1 = 0xffff; dut->in1 = 0xff & ~0x10; dut->p2 = 0xff;   // nothing pressed; IN1 bit4=0 stereo
    for (int i = 0; i < 8; i++) tick();

    // 68000 program: big-endian words
    for (long w = 0; w < MAINCPU_LEN / 2; w++) {
        dut->prog_we = 1; dut->prog_waddr = w; dut->prog_wdata = ((unsigned)prog[w*2] << 8) | prog[w*2+1]; tick();
    }
    dut->prog_we = 0;
    for (long w = 0; w < TILES_LEN / 4; w++) {
        dut->tile_we = 1; dut->tile_waddr = w;
        dut->tile_wdata = ((unsigned)tiles[w*4] << 24) | ((unsigned)tiles[w*4+1] << 16) | ((unsigned)tiles[w*4+2] << 8) | tiles[w*4+3];
        tick();
    }
    dut->tile_we = 0;
    for (long w = 0; w < ROZMAP_LEN / 2; w++) { dut->map_we = 1; dut->map_waddr = w; dut->map_wdata = ((unsigned)rmap[w*2] << 8) | rmap[w*2+1]; tick(); }
    dut->map_we = 0;
    for (long w = 0; w < ROZCHAR_LEN / 2; w++) { dut->chr_we = 1; dut->chr_waddr = w; dut->chr_wdata = ((unsigned)rchr[w*2] << 8) | rchr[w*2+1]; tick(); }
    dut->chr_we = 0;
    for (long w = 0; w < SPRITES_LEN / 8; w++) {
        unsigned long long v = 0; for (int b = 0; b < 8; b++) v = (v << 8) | spr[w*8+b];
        dut->spr_we = 1; dut->spr_waddr = w; dut->spr_wdata = v; tick();
    }
    dut->spr_we = 0;
    for (int i = 0; i < EEPROM_LEN; i++) { dut->eep_we = 1; dut->eep_waddr = i; dut->eep_wdata = eep[i]; tick(); }
    dut->eep_we = 0;

    dut->reset = 0;

    // run frames, capturing the visible pixels of the last one
    std::vector<unsigned> fb(VIS_W * VIS_H, 0);
    int snapevery = getenv("SNAPEVERY") ? atoi(getenv("SNAPEVERY")) : 0;
    auto save_frame = [&](const char *path) {
        FILE *o = fopen(path, "wb"); if (!o) return;
        fwrite(fb.data(), 4, fb.size(), o); fclose(o);
    };
    unsigned long long steps_total = 0;
    std::map<unsigned, unsigned> pc_hist;      // opcode-fetch addresses, last frame
    int frame = 0;
    bool prev_vblank = true;
    int x = 0, y = -1;
    unsigned irq_frames = 0; bool irq_seen = false, prev_irq = false;
    unsigned long long frame_steps = 0;
    unsigned de_pixels = 0;
    unsigned last_fetch = 0;
    unsigned logwin_lo = 0, logwin_hi = 0; unsigned logged = 0;
    // LOGRD=lo,hi[,lo2,hi2] (hex): log every data read inside these address
    // ranges as "frame addr data", the format tools/probe_reads.lua uses
    unsigned rd_lo[2] = {0, 0}, rd_hi[2] = {0, 0}; int nrd = 0;
    FILE *rdlog = nullptr;
    if (getenv("LOGRD")) { nrd = sscanf(getenv("LOGRD"), "%x,%x,%x,%x", &rd_lo[0], &rd_hi[0], &rd_lo[1], &rd_hi[1]) / 2; rdlog = fopen(getenv("RDLOG") ? getenv("RDLOG") : "rtl_reads.txt", "w"); }
    if (getenv("LOGWIN")) sscanf(getenv("LOGWIN"), "%x,%x", &logwin_lo, &logwin_hi);
    // WATCH=addr[,addr...] (hex): count opcode fetches of these per frame
    std::vector<unsigned> watch; std::vector<unsigned> watch_n;
    if (getenv("WATCH")) { char *w = strdup(getenv("WATCH")); for (char *t = strtok(w, ","); t; t = strtok(nullptr, ",")) { watch.push_back(strtoul(t, nullptr, 16)); watch_n.push_back(0); } }
    std::map<unsigned, unsigned> fr_hist;

    while (frame < frames) {
        tick();
        if (dut->dbg_step) {
            steps_total++; frame_steps++;
            if (rdlog && dut->dbg_busstate == 2) {
                unsigned a = dut->dbg_addr;
                for (int i = 0; i < nrd; i++) if (a >= rd_lo[i] && a <= rd_hi[i]) { fprintf(rdlog, "%d %06x %04x\n", frame, a, (unsigned)dut->dbg_data); break; }
            }
            if (tr && logwin_hi && last_fetch >= logwin_lo && last_fetch <= logwin_hi && logged < 400) {
                fprintf(tr, "  bus f%d %s %06x = %04x\n", frame,
                        dut->dbg_busstate == 0 ? "fetch" : dut->dbg_busstate == 3 ? "write" : "read ",
                        (unsigned)dut->dbg_addr, (unsigned)dut->dbg_data);
                logged++;
            }
            if (dut->dbg_busstate == 0) {
                last_fetch = dut->dbg_addr;
                fr_hist[last_fetch]++;
                for (size_t i = 0; i < watch.size(); i++) if (watch[i] == last_fetch) watch_n[i]++;
                if (frame == frames - 1) pc_hist[last_fetch]++;
            }
        }
        if (dut->dbg_irq5 && !prev_irq) irq_seen = true;
        prev_irq = dut->dbg_irq5;
        if (dut->cen_pix) {
            if (dut->de) {
                if (frame == frames - 1 || (snapevery && ((frame + 1) % snapevery) == 0)) {
                    if (y >= 0 && y < VIS_H && x < VIS_W) fb[y * VIS_W + x] = dut->rgb;
                }
                x++; de_pixels++;
            } else if (x) { x = 0; y++; }
            if (dut->vblank && !prev_vblank) {
                // end of a frame
                if (tr) {
                    unsigned hot = 0, hotn = 0;
                    for (auto &kv : fr_hist) if (kv.second > hotn) { hotn = kv.second; hot = kv.first; }
                    fprintf(tr, "frame %d: steps=%llu irq5=%d objs=%u overrun=%d unsup=%d de_px=%u pc=%06x hot=%06x(%u)\n",
                            frame, frame_steps, irq_seen, (unsigned)dut->dbg_objcount,
                            (int)dut->dbg_overrun, (int)dut->dbg_unsupported, de_pixels, last_fetch, hot, hotn);
                    for (size_t i = 0; i < watch.size(); i++) { fprintf(tr, "   watch %06x: %u\n", watch[i], watch_n[i]); watch_n[i] = 0; }
                    fr_hist.clear();
                }
                if (irq_seen) irq_frames++;
                irq_seen = false; frame_steps = 0; de_pixels = 0;
                if (snapevery && ((frame + 1) % snapevery) == 0) {
                    char path[512]; snprintf(path, sizeof path, "%s.f%d", argv[3], frame + 1);
                    save_frame(path);
                }
                frame++; y = -1; x = 0;
            }
            prev_vblank = dut->vblank;
        }
    }

    FILE *of = fopen(argv[3], "wb");
    if (!of) { fprintf(stderr, "cannot write %s\n", argv[3]); return 1; }
    fwrite(fb.data(), 4, fb.size(), of); fclose(of);

    printf("%d frames, %llu clocks, %llu kernel steps (%.1f per frame)\n",
           frames, cycles, steps_total, (double)steps_total / frames);
    printf("IRQ5 seen in %u of %d frames; objects in list: %u; overrun=%d unsupported=%d shadow_overlap=%d\n",
           irq_frames, frames, (unsigned)dut->dbg_objcount,
           (int)dut->dbg_overrun, (int)dut->dbg_unsupported, (int)dut->dbg_shadow_overlap);
    // top opcode-fetch addresses in the last frame: where the CPU is spending time
    std::vector<std::pair<unsigned, unsigned>> top(pc_hist.begin(), pc_hist.end());
    std::sort(top.begin(), top.end(), [](auto &a, auto &b){ return a.second > b.second; });
    printf("hottest fetch addresses in the last frame:");
    for (size_t i = 0; i < top.size() && i < 6; i++) printf(" %06x(%u)", top[i].first, top[i].second);
    printf("\n");
    if (tr) fclose(tr);
    if (rdlog) fclose(rdlog);
    delete dut;
    return 0;
}
