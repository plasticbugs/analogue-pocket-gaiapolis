// gaia_mem gate: samples of every ROM region go in through the download port
// and come back through every core port; the tile RAM is written and read.
//   tb_mem <gaiapolis.rom> [load gap in clocks, default 8]
#include "Vtb_mem_top.h"
#include "Vtb_mem_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>

static Vtb_mem_top *dut;
static unsigned long long cycles = 0;
static void tick(int n = 1) { while (n--) { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cycles++; } }
static const long IMG_PROG = 0x0000000, IMG_SND = 0x0300000, IMG_TILE = 0x0340000, IMG_CHR = 0x0540000,
                  IMG_MAP = 0x06C0000, IMG_PCM = 0x0760000, IMG_SPR = 0x0B60000, IMG_EEP = 0x1360000;
static std::vector<unsigned char> img;
static unsigned errors = 0;
static int load_gap = 8;            // clocks between download bytes (the APF loader delivers at most one per 8)

static void load(long a0, long n) {
    for (long a = a0; a < a0 + n; a++) {
        dut->dl_we = 1; dut->dl_addr = a; dut->dl_data = img[a]; tick();
        dut->dl_we = 0; tick(load_gap - 1);
    }
}
static bool wait_ack(unsigned char &ack, const char *what) {
    for (int i = 0; i < 2000; i++) { tick(); if (ack) return true; }
    printf("timeout waiting for %s\n", what); errors++; return false;
}
static unsigned prog_rd(long w) { dut->prog_req = 1; dut->prog_addr = w; bool ok = wait_ack(dut->prog_ack, "prog"); unsigned q = dut->prog_q; dut->prog_req = 0; tick(2); return ok ? q : 0xdead; }
static unsigned snd_rd(long b)  { dut->snd_req = 1;  dut->snd_addr = b;  bool ok = wait_ack(dut->snd_ack, "snd");   unsigned q = dut->snd_q;  dut->snd_req = 0;  tick(2); return ok ? q : 0xdd; }
static unsigned pcm_rd(long b)  { dut->pcm_req = 1;  dut->pcm_addr = b;  bool ok = wait_ack(dut->pcm_ack, "pcm");   unsigned q = dut->pcm_q;  dut->pcm_req = 0;  tick(2); return ok ? q : 0xdd; }
static unsigned map_rd(long b)  { dut->map_req = 1;  dut->map_addr = b;  bool ok = wait_ack(dut->map_ack, "map");   unsigned q = dut->map_q;  dut->map_req = 0;  tick(2); return ok ? q : 0xdead; }
static unsigned chr_rd(long b)  { dut->chr_req = 1;  dut->chr_addr = b;  bool ok = wait_ack(dut->chr_ack, "chr");   unsigned q = dut->chr_q;  dut->chr_req = 0;  tick(2); return ok ? q : 0xdead; }
static unsigned tile_rd(long w) { dut->tile_req = 1; dut->tile_addr = w; bool ok = wait_ack(dut->tile_ack, "tile"); unsigned q = dut->tile_q; dut->tile_req = 0; tick(2); return ok ? q : 0xdeadbeef; }
static unsigned long long spr_rd(long w) { dut->spr_req = 1; dut->spr_addr = w; bool ok = wait_ack(dut->spr_ack, "spr"); unsigned long long q = dut->spr_q; dut->spr_req = 0; tick(2); return ok ? q : 0xdeadbeefdeadbeefULL; }
static void vram_wr(unsigned a, unsigned d, unsigned be) { dut->vram_req = 1; dut->vram_we = 1; dut->vram_addr = a; dut->vram_wdata = d; dut->vram_be = be; wait_ack(dut->vram_ack, "vram write"); dut->vram_req = 0; dut->vram_we = 0; tick(2); }
static unsigned vram_rd(unsigned a) { dut->vram_req = 1; dut->vram_we = 0; dut->vram_addr = a; bool ok = wait_ack(dut->vram_ack, "vram read"); unsigned q = dut->vram_q; dut->vram_req = 0; tick(2); return ok ? q : 0xdead; }
static unsigned be16(long a) { return ((unsigned)img[a] << 8) | img[a + 1]; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s <rom>\n", argv[0]); return 2; }
    FILE *rf = fopen(argv[1], "rb"); if (!rf) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
    fseek(rf, 0, SEEK_END); long n = ftell(rf); fseek(rf, 0, SEEK_SET);
    img.resize(n); if (fread(img.data(), 1, n, rf) != (size_t)n) return 1; fclose(rf);

    if (argc > 2) load_gap = atoi(argv[2]);
    dut = new Vtb_mem_top;
    dut->init = 1; tick(8); dut->init = 0;
    int w = 0; while (!dut->ready && w++ < 200000) tick();
    if (!dut->ready) { printf("SDRAM never ready\n"); return 1; }
    printf("SDRAM ready after %llu clocks\n", cycles);

    if (argc > 3) {                     // probe: two bytes, one word back
        img[0] = 0x12; img[1] = 0x34; load(0, 2); tick(100);
        printf("probe word 0: %04x (expect 1234)\n", prog_rd(0));
        printf("probe word 0 again: %04x\n", prog_rd(0));
        // a lone even byte (flushed by the timeout), then a lone odd byte
        img[4] = 0x56; img[7] = 0x78; load(4, 1); tick(400); load(7, 1); tick(400);
        printf("probe word 2: %04x (expect 5600)  word 3: %04x (expect 0078)\n", prog_rd(2), prog_rd(3));
        // an odd byte then its even neighbour in reverse order: two single writes
        img[10] = 0x9a; img[11] = 0xbc; load(11, 1); load(10, 1); tick(400);
        printf("probe word 5: %04x (expect 9abc)\n", prog_rd(5));
        delete dut; return 0;
    }
    // samples: the first and last 2 KB of every region, all of the EEPROM
    const long S = 2048;
    struct { const char *name; long base, len; } regs[] = {
        {"prog", IMG_PROG, IMG_SND - IMG_PROG}, {"snd", IMG_SND, IMG_TILE - IMG_SND}, {"tile", IMG_TILE, IMG_CHR - IMG_TILE},
        {"chr", IMG_CHR, IMG_MAP - IMG_CHR}, {"map", IMG_MAP, IMG_PCM - IMG_MAP}, {"pcm", IMG_PCM, IMG_SPR - IMG_PCM},
        {"spr", IMG_SPR, IMG_EEP - IMG_SPR} };
    unsigned eep_writes = 0, eep_bad = 0;
    for (auto &r : regs) { load(r.base, S); load(r.base + r.len - S, S); }
    // the EEPROM: collect the bytes handed to the core
    int eep_got[128]; for (int i = 0; i < 128; i++) eep_got[i] = -1;
    auto eep_watch = [&](int n) { while (n--) { tick(); if (dut->eep_we) { eep_writes++; eep_got[dut->eep_addr] = dut->eep_data; } } };
    for (long a = IMG_EEP; a < IMG_EEP + 128; a++) {
        dut->dl_we = 1; dut->dl_addr = a; dut->dl_data = img[a]; eep_watch(1); dut->dl_we = 0; eep_watch(load_gap - 1);
    }
    eep_watch(400);
    for (int i = 0; i < 128; i++) if (eep_got[i] != img[IMG_EEP + i]) eep_bad++;
    printf("loaded; eeprom bytes delivered %u (bad %u)\n", eep_writes, eep_bad);
    if (eep_writes != 128 || eep_bad) errors++;

    // read back, every port, both sample windows
    auto check = [&](const char *name, long base, long len, auto rd, long unit, auto expect) {
        unsigned bad = 0, cnt = 0;
        for (int win = 0; win < 2; win++) {
            long off0 = win ? len - S : 0;
            for (long off = off0; off < off0 + S; off += unit) {
                long a = base + off; unsigned long long got = rd(off / unit, off), exp = expect(a);
                cnt++;
                if (got != exp) { if (bad < 4) printf("  %s @ image %07lx: got %llx expected %llx\n", name, a, got, exp); bad++; }
            }
        }
        printf("%-5s %u words checked, %u bad\n", name, cnt, bad); errors += bad;
    };
    check("prog", IMG_PROG, IMG_SND - IMG_PROG, [](long w, long){ return (unsigned long long)prog_rd(w); }, 2, [](long a){ return (unsigned long long)be16(a); });
    check("snd",  IMG_SND, IMG_TILE - IMG_SND,  [](long, long off){ return (unsigned long long)snd_rd(off); }, 1, [](long a){ return (unsigned long long)img[a]; });
    check("tile", IMG_TILE, IMG_CHR - IMG_TILE, [](long w, long){ return (unsigned long long)tile_rd(w); }, 4,
          [](long a){ return (unsigned long long)(((unsigned)be16(a) << 16) | be16(a + 2)); });
    check("chr",  IMG_CHR, IMG_MAP - IMG_CHR,   [](long, long off){ return (unsigned long long)chr_rd(off); }, 2, [](long a){ return (unsigned long long)be16(a); });
    check("map",  IMG_MAP, IMG_PCM - IMG_MAP,   [](long, long off){ return (unsigned long long)map_rd(off); }, 2, [](long a){ return (unsigned long long)be16(a); });
    check("pcm",  IMG_PCM, IMG_SPR - IMG_PCM,   [](long, long off){ return (unsigned long long)pcm_rd(off); }, 1, [](long a){ return (unsigned long long)img[a]; });
    check("spr",  IMG_SPR, IMG_EEP - IMG_SPR,   [](long w, long){ return spr_rd(w); }, 8,
          [](long a){ unsigned long long v = 0; for (int b = 0; b < 8; b++) v = (v << 8) | img[a + b]; return v; });

    // tile RAM: words and byte lanes
    unsigned vbad = 0;
    for (unsigned a = 0; a < 64; a++) vram_wr(a * 1021 & 0xffff, (a * 0x3579) & 0xffff, 3);
    for (unsigned a = 0; a < 64; a++) { unsigned e = (a * 0x3579) & 0xffff, g = vram_rd(a * 1021 & 0xffff); if (g != e) { if (vbad < 4) printf("  vram %04x: got %04x expected %04x\n", a * 1021 & 0xffff, g, e); vbad++; } }
    vram_wr(0x1234, 0xaa55, 3); vram_wr(0x1234, 0x11ff, 2); { unsigned g = vram_rd(0x1234); if (g != 0x1155) { printf("  vram byte lane: got %04x expected 1155\n", g); vbad++; } }
    vram_wr(0x1234, 0x22cc, 1); { unsigned g = vram_rd(0x1234); if (g != 0x11cc) { printf("  vram byte lane: got %04x expected 11cc\n", g); vbad++; } }
    printf("vram  %u bad\n", vbad); errors += vbad;

    // the built-in memory test (1/64 of each region): reload the heads of
    // the regions so the load-time sums restart at image byte 0, run it,
    // then corrupt one word in a PSRAM and one in the SDRAM and run it again
    bool poke_vram = false;             // corrupt two tile RAM words once the read-back pass has begun
    auto run_test = [&](const char *what, unsigned exp_ok) {
        dut->test_start = 1; tick(4); dut->test_start = 0;
        long n = 0; bool poked = false;
        while (!dut->test_done && n++ < 60000000) {
            tick();
            if (poke_vram && !poked && dut->rootp->tb_mem_top__DOT__dut__DOT__u_test__DOT__st == 4) {   // T_VR
                dut->rootp->tb_mem_top__DOT__sram__DOT__mem[0x8234] ^= 0x0001;
                dut->rootp->tb_mem_top__DOT__sram__DOT__mem[0x8235] ^= 0x8000; poked = true;
            }
        }
        printf("memtest %s: done=%d ok=%02x stable=%02x vram_ok=%d vram_bad=%d (%ld clocks)\n", what, dut->test_done,
               dut->test_ok, dut->test_stable, dut->vram_ok, dut->vram_bad, n);
        if (!dut->test_done || dut->test_ok != exp_ok || dut->test_stable != 0x7f || !dut->vram_ok) errors++;
    };
    for (auto &r : regs) load(r.base, S);
    run_test("clean", 0x7f);
    dut->ps_slow = 1; dut->sram_slow = 1; dut->sram_slow_wr = 1; run_test("clean, slow captures and writes", 0x7f);
    dut->ps_slow = 0; dut->sram_slow = 0; dut->sram_slow_wr = 0;
    // two bad tile RAM words show as 2 on the log scale
    poke_vram = true; run_test("corrupted tile RAM (2 words, expect vram_bad 2)", 0x7f); poke_vram = false;
    if (dut->vram_bad == 2 && !dut->vram_ok) errors--;                  // run_test counted the expected failure
    else printf("  tile RAM corruption not reported as 2\n");
    dut->rootp->tb_mem_top__DOT__cram1__DOT__mem[5] ^= 0x0100;         // prog word 5
    dut->rootp->tb_mem_top__DOT__chip__DOT__mem[7] ^= 0x0001;          // tile word 7
    run_test("corrupted prog+tile", 0x7f & ~0x01 & ~0x04);         // bit 0 prog, bit 2 tile
    printf("%s: %u errors, %llu clocks\n", errors ? "FAIL" : "PASS", errors, cycles);
    delete dut; return errors ? 1 : 0;
}
