#include "fenster.h"
#include "Vproject.h"
#include "verilated.h"

const int PAD = 48;
const int W = 640 + PAD * 2;
const int H = 480 + PAD * 2;

struct Bits {
    uint8_t r1:1, g1:1, b1:1, vsync:1, r0:1, g0:1, b0:1, hsync:1;
};

static inline uint32_t bits2channel(uint8_t lo, uint8_t hi, int ch) {
    return (hi * 170 + lo * 85) << (ch * 8);
}

static void reset_mod(Vproject &mod) {
    mod.rst_n = 0;
    mod.eval();
    mod.clk = 1;
    mod.eval();
    mod.clk = 0;
    mod.rst_n = 1;
    mod.eval();
}

static void dump_ppm(const char *filename, const uint32_t *pixels, int w, int h) {
    FILE *f = fopen(filename, "wb");
    if (!f) {
        fprintf(stderr, "Failed to open %s for writing\n", filename);
        return;
    }
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int i = 0; i < w * h; ++i) {
        uint32_t p = pixels[i];
        uint8_t rgb[3] = {
            static_cast<uint8_t>((p >> 16) & 0xFF),
            static_cast<uint8_t>((p >> 8) & 0xFF),
            static_cast<uint8_t>(p & 0xFF)
        };
        fwrite(rgb, 1, 3, f);
    }
    fclose(f);
    printf("Saved first frame to %s\n", filename);
}

const int INIT_X = PAD; // H_BACK (48 pixels from hsync falling edge to active area)
const int INIT_Y = 33;  // V_TOP  (33 lines from vsync falling edge to active area)

int main(int argc, char* argv[]) {
    Fenster f(W, H, "VGA Simulation");
    uint32_t *pixels = f.f.buf;

    Vproject mod;
    mod.ena = 1;
    mod.clk = 0;
    mod.ui_in = 0;
    reset_mod(mod);

    Bits prev = *(Bits*)(&mod.uo_out);
    int x = INIT_X, y = INIT_Y;
    bool paused = false;
    bool prev_key_p = false;
    bool prev_key_step = false;
    bool prev_key_r = false;
    bool prev_key_num[8] = {false};
    bool first_frame_saved = false;

    printf("\n=== Interactive Controls ===\n");
    printf("  [1]..[8]   : Toggle ui_in[0]..ui_in[7]\n");
    printf("  [P]        : Pause / Resume\n");
    printf("  [.] or [S] : Step 1 frame (while paused)\n");
    printf("  [R]        : Reset simulation\n\n");

    while (f.loop(60) && !f.key(27)) {
        // Toggle ui_in[0..7] with keys 1..8
        for (int i = 0; i < 8; ++i) {
            bool k = f.key('1' + i);
            if (k && !prev_key_num[i]) {
                mod.ui_in ^= (1 << i);
                printf("ui_in[%d] = %d (ui_in = 0x%02X)\n", i, (mod.ui_in >> i) & 1, mod.ui_in);
            }
            prev_key_num[i] = k;
        }

        // Pause toggle
        bool key_p = f.key('p') || f.key('P');
        if (key_p && !prev_key_p) {
            paused = !paused;
            printf("Paused: %s\n", paused ? "YES" : "NO");
        }
        prev_key_p = key_p;

        // Step 1 frame
        bool key_step = f.key('.') || f.key('s') || f.key('S');
        bool do_single_step = paused && key_step && !prev_key_step;
        prev_key_step = key_step;

        // Reset
        bool key_r = f.key('r') || f.key('R');
        if (key_r && !prev_key_r) {
            printf("Resetting simulation...\n");
            reset_mod(mod);
            prev = *(Bits*)(&mod.uo_out);
            x = INIT_X;
            y = INIT_Y;
        }
        prev_key_r = key_r;

        if (paused && !do_single_step) {
            continue;
        }

        while (true) {
            mod.clk = !mod.clk;
            mod.eval();
            Bits v = *(Bits*)(&mod.uo_out);
            if (prev.hsync && !v.hsync) {
                x = 0;
                y += 1;
            }
            bool vsync = prev.vsync && !v.vsync;
            if (vsync) {
                x = 0;
                y = 0;
            }
            if (x < W && y < H) {
                pixels[y * W + x] = bits2channel(v.b0, v.b1, 0) | 
                                    bits2channel(v.g0, v.g1, 1) | 
                                    bits2channel(v.r0, v.r1, 2);
            }
            prev = v;

            x += mod.clk;
            if (vsync) {
                break;
            }
        }

        if (!first_frame_saved) {
            dump_ppm("vga.ppm", pixels, W, H);
            first_frame_saved = true;
        }
    }
    return 0;
}

