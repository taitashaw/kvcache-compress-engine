# Hardware KV-Cache Compression Engine
## Complete Implementation Plan: Start-to-Finish

### Lessons Applied from the Softmax Project

The flashattn-softmax-engine succeeded because it followed a disciplined 8-phase methodology. Every phase had a measurable gate — no phase started until the previous one passed. Here's what worked and what we're replicating:

| Softmax Phase | What Worked | KV-Cache Equivalent |
|---------------|-------------|---------------------|
| 1. Research the real bottleneck | MUFU 256× gap, not approximate attention | KV-cache HBM explosion, not model size |
| 2. Python golden model | Bit-exact FlashAttention-2 reference | Bit-exact KV-cache compress/decompress |
| 3. RTL design (SystemVerilog) | pipelined_exp.sv as core innovation | quantizer_engine.sv as core innovation |
| 4. Testbench with THE METRIC | PERF_STALL_CYCLES = 0 | COMPRESSION_RATIO = 8× at RMSE < 0.01 |
| 5. Verilator lint + sim | Zero warnings, 16/16 PASS | Zero warnings, all tests PASS |
| 6. Vivado xsim + waveforms | Visual proof of pipeline operation | Visual proof of compress/decompress |
| 7. Synthesis at aggressive freq | 400 MHz, WNS = +0.413 ns | 400 MHz target |
| 8. Block design + bitstream | Zynq PS + AXI + bitstream | Zynq PS + AXI + DMA + bitstream |

---

## THE PROBLEM

### The KV-Cache Memory Wall

Every LLM inference deployment hits the same wall: KV-cache memory grows linearly with sequence length and batch size.

```
KV-Cache Size = 2 × num_layers × num_heads × seq_len × head_dim × bytes_per_element

Llama-3 70B (FP16, seq_len=128K):
  2 × 80 × 64 × 128,000 × 128 × 2 bytes = 167 GB

That's MORE than the H100's entire 80 GB HBM3.
Even with FP8: 83 GB. Still doesn't fit.
```

This is why:
- NVIDIA Blackwell ships with 192 GB HBM3e (mostly for KV-cache)
- Groq's SRAM-only architecture is entirely KV-cache constrained
- Every serving framework (vLLM, TGI, TensorRT-LLM) spends 60-80% of memory on KV-cache
- Batch size is limited by KV-cache, not compute — killing throughput/dollar

**The architectural question:** What if KV-cache entries were compressed in hardware as they're written to HBM, and decompressed as they're read back — transparently, at line rate, with negligible accuracy loss?

### The Metric

```
COMPRESSION_RATIO ≥ 8×  (FP16 → effective 2-bit per element)
RMSE < 0.01             (vs. uncompressed reference)
DECOMPRESS_LATENCY ≤ 1 cycle per element  (no pipeline stalls)
```

This is the KV-Cache equivalent of PERF_STALL_CYCLES = 0.

---

## THE SOLUTION

### Architecture Overview

```
                ┌──────────────────────────────────────────────────┐
                │        KV-Cache Compression Engine                │
                │                                                  │
  From          │  ┌─────────────┐    ┌───────────────┐            │
  Attention ────┼─▶│  Quantizer   │───▶│  Token Evictor │──┐       │
  (K/V tiles)   │  │  FP16→INT2  │    │  Score-based   │  │       │  To HBM
                │  │  + Outlier   │    │  Pruning       │  ├──────┼──────▶
                │  │  Protection  │    │                │  │       │  (Compressed)
                │  └─────────────┘    └───────────────┘  │       │
                │                                         │       │
                │  ┌─────────────────────────────────────┘       │
                │  │  Metadata:  scales, outlier bitmap, evict mask│
                │  └─────────────────────────────────────────────┘│
                │                                                  │
  To            │  ┌─────────────┐    ┌───────────────┐            │
  Attention ◀───┼──│ Dequantizer │◀───│  Cache Reader │◀───────────┼── From HBM
  (restored)    │  │  INT2→FP16  │    │  + Zero-fill   │            │  (Compressed)
                │  │  + Outlier   │    │  evicted tokens│            │
                │  │  Restore    │    │                │            │
                │  └─────────────┘    └───────────────┘            │
                │                                                  │
                │  AXI4-Lite CSR  │  AXI4-Stream Data  │  IRQ     │
                └──────────────────────────────────────────────────┘
```

### Core Innovation: Group Quantization with Outlier Protection

Standard INT2 quantization destroys attention accuracy because a few outlier values dominate the dynamic range. Our engine uses **group quantization** (groups of 64 elements share a scale factor) with **outlier extraction** (top 1% of values stored separately at full precision).

```
Per group of 64 elements:
  1. Compute max absolute value → scale = max / 1.5 (for INT2: -2,-1,0,1)
  2. Identify outliers: |x| > 4σ of group (typically 0-1 per group)
  3. Quantize non-outliers: round(x / scale) → 2-bit
  4. Store: 64×2-bit values (128 bits) + 1 scale (16 bits) + outlier bitmap (64 bits) + outlier values

  Compressed size per group: 128 + 16 + 64 + ~16 = 224 bits
  Original size: 64 × 16 = 1,024 bits
  Compression ratio: 1024/224 = 4.57× (quantization alone)

  With token eviction (50% of low-attention tokens):
  Effective ratio: ~8×
```

### Token Eviction: Attention-Score-Based Pruning

Not all KV-cache entries matter equally. Recent work (H2O, StreamingLLM, SnapKV) shows that only 20-50% of cached tokens receive meaningful attention. The engine maintains a running attention score accumulator per token position and evicts tokens below a programmable threshold.

```
Per token position:
  attn_score_acc += sum(softmax_row[token_pos])  // accumulated across layers
  if attn_score_acc < EVICTION_THRESHOLD:
    mark for eviction → don't write to HBM
```

---

## TOOL REQUIREMENTS

### Required Tools (same workstation as softmax project)

| Tool | Version | Purpose | Phase |
|------|---------|---------|-------|
| **Python 3.8+** | 3.8+ | Golden model, test vector generation | 1 |
| **NumPy** | Latest | Matrix operations, quantization math | 1 |
| **PyTorch** | 2.0+ | Reference KV-cache from real LLM inference | 1 |
| **VS Code** | Latest | RTL editing, integrated terminal | 2-8 |
| **Verilator** | 5.x | RTL lint + cycle-accurate simulation | 3-4 |
| **GTKWave** | Any | VCD waveform viewing | 4 |
| **Vivado** | 2024.2+ | xsim, synthesis, block design, bitstream | 5-8 |
| **Vitis HLS** | 2024.2+ | Optional: rapid prototyping of quantizer | 2 |
| **Git** | Latest | Version control | All |
| **Make** | Latest | Build automation | All |

### New Tool: Vitis HLS (Not Used in Softmax Project)

For the KV-Cache project, **Vitis HLS** is valuable for one specific purpose: rapidly prototyping the group quantization algorithm in C++ before writing the final SystemVerilog. The quantizer has more complex control flow than the softmax exp unit (outlier detection, variable-length encoding, group boundaries), so getting the algorithm right in C++ first saves weeks of RTL debugging.

**However:** The final deliverable is still hand-written SystemVerilog. Vitis HLS output is used as a reference implementation, not as production RTL. This matters for the portfolio — hand-written RTL demonstrates mastery; HLS-generated RTL demonstrates tool usage.

### VS Code Extensions

| Extension | Purpose |
|-----------|---------|
| SystemVerilog - Language Support | Syntax highlighting, linting |
| Verilog-HDL/SystemVerilog | Auto-formatting, module hierarchy |
| WaveTrace | VCD waveform viewing (lightweight alternative to GTKWave) |
| C/C++ | For Vitis HLS prototyping |
| Python | For golden model development |

---

## IMPLEMENTATION PATHWAY: 8 PHASES

### Phase 1: Golden Model (Week 1)
**Gate: Python model produces bit-exact compress/decompress with measured RMSE < 0.01**

```
File: model/golden_model.py (~600 lines)

What it does:
  1. Loads real KV-cache tensors from a Llama-3 8B inference run (PyTorch)
  2. Implements group quantization: FP16 → INT2 with per-group scales
  3. Implements outlier extraction: bitmap + full-precision storage
  4. Implements token eviction: attention-score-based pruning
  5. Implements decompression: INT2 → FP16 with outlier restoration
  6. Measures RMSE, max error, compression ratio
  7. Generates test vectors (binary files) for RTL verification
  8. Produces HBM bandwidth analysis (compressed vs. uncompressed)

Key outputs:
  - test_vectors/compress_input_N.bin    (FP16 KV tiles)
  - test_vectors/compress_output_N.bin   (compressed bitstream)
  - test_vectors/decompress_output_N.bin (restored FP16)
  - test_vectors/metadata_N.bin          (scales, bitmaps, evict masks)
  - Accuracy report: RMSE per layer, per head
  - Compression report: ratio per layer, overall

Build command: make golden
```

**Detailed algorithm (what the Python implements):**

```python
def group_quantize(kv_tile, group_size=64):
    """
    kv_tile: [seq_len, head_dim] FP16
    Returns: compressed bitstream + metadata
    """
    groups = kv_tile.reshape(-1, group_size)  # [N_groups, 64]

    for group in groups:
        # Step 1: Statistics
        mu = group.mean()
        sigma = group.std()
        abs_max = group.abs().max()

        # Step 2: Outlier detection (|x| > 4σ)
        outlier_mask = group.abs() > (4 * sigma)
        outlier_values = group[outlier_mask]  # Store at FP16
        normal_values = group.clone()
        normal_values[outlier_mask] = 0  # Zero out outliers for quantization

        # Step 3: Group scale
        normal_max = normal_values.abs().max()
        scale = normal_max / 1.5  # INT2 range: {-2,-1,0,1} maps to {-1.5,-0.5,0,0.5}*scale

        # Step 4: Quantize to INT2
        quantized = torch.clamp(torch.round(normal_values / scale), -2, 1)

        # Step 5: Pack
        # 64 × 2-bit = 128 bits = 16 bytes
        # 1 × FP16 scale = 2 bytes
        # 64-bit outlier bitmap = 8 bytes
        # N × FP16 outlier values = 2N bytes (typically 0-2 values)

    return compressed_stream, metadata

def token_evict(attn_scores, kv_cache, threshold):
    """
    attn_scores: [seq_len] accumulated attention scores
    kv_cache: compressed KV entries
    threshold: eviction threshold (programmable via CSR)
    Returns: evicted cache (tokens below threshold zeroed)
    """
    keep_mask = attn_scores >= threshold
    # Keep recent tokens always (sliding window protection)
    keep_mask[-WINDOW_SIZE:] = True
    return kv_cache[keep_mask], keep_mask
```

### Phase 2: RTL Design (Week 2-3)
**Gate: All modules pass Verilator lint with zero warnings**

```
Files:
  rtl/group_quantizer.sv       (~250 lines) — Core: FP16→INT2 per group
  rtl/outlier_detector.sv      (~180 lines) — 4σ threshold, bitmap generation
  rtl/token_evictor.sv         (~200 lines) — Score accumulator + threshold compare
  rtl/dequantizer.sv           (~200 lines) — INT2→FP16 with outlier restore
  rtl/kvcache_compress_top.sv  (~400 lines) — AXI4-Stream + AXI4-Lite CSR + FSM
  rtl/kvcache_compress_wrapper.v (~70 lines) — Verilog wrapper for block design

Total: ~1,300 lines of SystemVerilog
```

**Module-by-module design:**

#### rtl/group_quantizer.sv — The Core Innovation

```
Pipelined group quantization engine. Processes 64 FP16 elements per group.

Pipeline stages (8 stages, 1 group per 64+8 cycles):

  Stage 1: Ingest 64 elements (64 cycles, streaming via AXI4-Stream)
           Store in local register file [63:0][15:0]
           Compute running |max| and running sum for mean

  Stage 2: Compute group statistics
           abs_max = max of all 64 |values|
           mean = sum / 64
           Start σ computation (sum of squared differences)

  Stage 3: Complete σ computation
           sigma = sqrt(variance) — use pipelined_sqrt or LUT approximation
           threshold = 4 × sigma (shift left by 2)

  Stage 4: Outlier detection pass
           For each element: outlier_mask[i] = (|element[i]| > threshold)
           Count outliers (popcount of mask)
           Compute normal_max (max of non-outlier elements)

  Stage 5: Scale computation
           scale = normal_max × (2/3)  (maps ±1.5 range to ±normal_max)
           inv_scale = 1/scale (for division-free quantization)

  Stage 6: Quantization pass
           For each non-outlier element:
             q[i] = clamp(round(element[i] × inv_scale), -2, 1)
           Pack 64 × 2-bit values into 128-bit word

  Stage 7: Output packing
           Emit: [128-bit quantized data]
                 [16-bit scale]
                 [64-bit outlier bitmap]
                 [N × 16-bit outlier values]

  Stage 8: Metadata write
           Update compression statistics counters

CSR registers:
  GROUP_SIZE (default 64, configurable 32/64/128)
  OUTLIER_THRESHOLD (default 4σ, configurable 2-8σ)
  QUANT_BITS (default 2, configurable 2/4/8 for INT2/INT4/INT8)
```

#### rtl/dequantizer.sv — Mirror Pipeline

```
Decompression pipeline. Must match compress latency for streaming operation.

  Stage 1: Read compressed group from AXI4-Stream
           Parse: quantized data, scale, outlier bitmap, outlier values

  Stage 2: Dequantize
           For each element: restored[i] = quantized[i] × scale

  Stage 3: Outlier restoration
           For each bit set in outlier_bitmap:
             restored[i] = outlier_value[popcount(bitmap[i-1:0])]

  Stage 4: Output via AXI4-Stream
           64 FP16 elements, 1 per cycle

  Throughput: 1 element/cycle after initial latency
  This is the DECOMPRESS_LATENCY ≤ 1 cycle metric
```

#### rtl/token_evictor.sv

```
Maintains per-token attention score accumulators.

  Inputs:
    - Attention scores from softmax output (per token)
    - Programmable eviction threshold (via CSR)
    - Sliding window size (always keep recent N tokens)

  Storage: BRAM-based score table
    - [MAX_SEQ_LEN][31:0] — 32-bit accumulator per token position
    - Updated every attention layer

  Eviction decision:
    - After all layers: compare accumulator vs. threshold
    - Generate eviction bitmask
    - Protected window: last W tokens never evicted

  Output: eviction_mask[MAX_SEQ_LEN-1:0]
```

#### rtl/kvcache_compress_top.sv — Top Level

```
Interfaces:
  - AXI4-Stream Slave:  KV data in (from attention unit, FP16)
  - AXI4-Stream Master: Compressed data out (to HBM via DMA)
  - AXI4-Stream Slave:  Compressed data in (from HBM for decompression)
  - AXI4-Stream Master: Restored KV data out (to attention unit, FP16)
  - AXI4-Lite Slave:    CSR register access (from PS/host)
  - IRQ output:         Compression/decompression complete

CSR Register Map:
  0x00  CTRL            [0] Start compress, [1] Start decompress
  0x04  STATUS          [0] Busy, [1] Done, [2] Error
  0x08  SEQ_LEN         Current sequence length
  0x0C  NUM_HEADS       Number of KV heads
  0x10  HEAD_DIM        Head dimension
  0x14  GROUP_SIZE      Quantization group size (32/64/128)
  0x18  QUANT_BITS      Bits per element (2/4/8)
  0x1C  OUTLIER_THRESH  Outlier detection threshold (in σ units, Q4.4)
  0x20  EVICT_THRESH    Token eviction threshold (Q16.16)
  0x24  WINDOW_SIZE     Protected sliding window size
  0x28  SRC_BASE        Source data HBM base address
  0x2C  DST_BASE        Destination HBM base address
  0x30  PERF_CYCLES           Total cycles
  0x34  PERF_COMPRESS_CYCLES  Compression cycles
  0x38  PERF_DECOMPRESS_CYCLES Decompression cycles
  0x3C  PERF_COMPRESSION_RATIO ★ THE METRIC (Q8.8 fixed point) ★
  0x40  PERF_RMSE             Measured RMSE (Q8.24)
  0x44  PERF_TOKENS_EVICTED   Number of tokens evicted
  0x48  PERF_OUTLIERS_DETECTED Total outliers across all groups
  0x4C  PERF_BYTES_SAVED      HBM bytes saved vs. uncompressed
```

### Phase 3: Testbench (Week 3)
**Gate: All tests PASS in Verilator, COMPRESSION_RATIO ≥ 8×, RMSE < 0.01**

```
File: tb/tb_top.sv (~500 lines)

Test plan:
  TEST 1: CSR Register Write/Read (same pattern as softmax)
  TEST 2: Single Group Compress/Decompress (64 elements, no outliers)
  TEST 3: Group with Outliers (inject 2 outlier values, verify bitmap)
  TEST 4: Full Tile Compress (128×128 tile, multiple groups)
  TEST 5: Token Eviction (set threshold, verify eviction mask)
  TEST 6: Decompress and Compare (vs. golden model vectors)
  TEST 7: Compression Ratio Check ★ THE METRIC ★
  TEST 8: RMSE Check ★ THE METRIC ★
  TEST 9: Back-to-back Compress/Decompress (streaming throughput)
  TEST 10: Re-start with Different Config (INT4 mode)

Key assertions:
  - PERF_COMPRESSION_RATIO >= 8.0 (Q8.8: 0x0800)
  - PERF_RMSE < 0.01 (Q8.24: 0x00028F)
  - PERF_DECOMPRESS_CYCLES / num_elements <= 1 (line-rate decompression)
  - All decompressed values match golden model within tolerance

Build command: make sim
Expected: XX/XX PASS, COMPRESSION_RATIO ≥ 8×, RMSE < 0.01
```

### Phase 4: Vivado xsim + Waveforms (Week 3)
**Gate: Same tests pass in Vivado xsim, waveforms captured**

```
File: vivado/sim.tcl (same structure as softmax)

Key waveform signals to capture:
  - compress_fsm_state (watch pipeline stages)
  - group_scale (verify per-group scale computation)
  - outlier_bitmap (verify outlier detection)
  - eviction_mask (verify token eviction)
  - perf_compression_ratio (THE METRIC)
  - perf_rmse (THE METRIC)
  - s_axis_tvalid/tready (AXI4-Stream handshakes)
  - m_axis_tvalid/tready (output streaming)

Build command: make xsim_gui
```

### Phase 5: Synthesis (Week 4)
**Gate: 400 MHz timing closure (WNS > 0), resource utilization documented**

```
File: vivado/synth.tcl (same structure as softmax)

Target: xczu7ev-ffvc1156-2-e (ZCU104) @ 400 MHz
  - Same false_path constraints on I/O (proven approach from softmax)
  - AXI4-Stream interfaces don't need I/O constraints

Expected utilization (estimate):
  LUTs:  2,000 - 4,000  (4× softmax due to quantizer + dequantizer)
  FFs:   3,000 - 5,000  (pipeline registers)
  DSPs:  4 - 8          (scale multiplication, σ computation)
  BRAM:  2 - 8          (token score table, group buffer)

Key: DSPs will NOT be zero this time (unlike softmax).
The scale × value multiplication needs real multipliers.
This is fine — it's a different architectural argument.

Build command: make synth
```

### Phase 6: Block Design + Bitstream (Week 4)
**Gate: Bitstream generated, XSA exported**

```
File: vivado/block_design.tcl

SoC architecture (more complex than softmax):
  ┌──────────┐     ┌──────────┐     ┌──────────────────┐
  │  Zynq PS │────▶│ AXI      │────▶│ KV-Cache         │
  │  ARM A53 │     │ Intercon │     │ Compress Engine   │
  │          │     │          │     │ (CSR via AXI-Lite)│
  └────┬─────┘     └────┬─────┘     └────┬──────┬──────┘
       │                │                │      │
       │           ┌────▼─────┐     AXI-Stream  AXI-Stream
       │           │ AXI DMA  │◀────(compress)  (decompress)
       │           │          │────▶
       │           └────┬─────┘
       │                │
       └────────────────┘
              DDR4

New vs. softmax block design:
  + AXI DMA engine (for streaming KV data between DDR4 and our IP)
  + AXI4-Stream interfaces (not just AXI4-Lite)
  + Larger address map (DMA needs scatter-gather descriptors)

Build command: make block_design
```

### Phase 7: Firmware (Week 4)
**Gate: Bare-metal firmware compiles, CSR access verified**

```
File: fw/main.c (~250 lines)

What it does:
  1. Initialize DMA engine
  2. Load test KV-cache data into DDR4
  3. Configure compression engine via CSR writes
  4. Start DMA transfer: DDR4 → compress engine → DDR4
  5. Wait for IRQ
  6. Read performance counters
  7. Start decompression: DDR4 → decompress engine → DDR4
  8. Compare decompressed vs. original (RMSE check on ARM)
  9. Print results

Build command: make firmware (cross-compile with Vitis)
```

### Phase 8: Documentation + GitHub + LinkedIn (Week 5)
**Gate: README renders, repo pushed, post drafted**

```
Same methodology as softmax:
  - README.md with architecture diagrams, results, quick start
  - img/ directory with waveform screenshots
  - ARCHITECTURE.md with detailed design document
  - LICENSE (MIT)
  - .gitignore
  - LinkedIn post following proven format
```

---

## PROJECT TIMELINE

```
Week 1:  Golden model in Python
         ├── Day 1-2: Research KV-cache compression papers (H2O, SnapKV, KIVI)
         ├── Day 3-4: Implement group quantization + outlier detection
         ├── Day 5:   Implement token eviction
         ├── Day 6:   Generate test vectors, measure RMSE + compression ratio
         └── Day 7:   HBM bandwidth analysis, documentation
         GATE: make golden → RMSE < 0.01, ratio ≥ 8×

Week 2:  RTL design — core modules
         ├── Day 1-2: group_quantizer.sv (pipelined, 8-stage)
         ├── Day 3:   outlier_detector.sv
         ├── Day 4:   dequantizer.sv (mirror pipeline)
         ├── Day 5:   token_evictor.sv (BRAM-based score table)
         ├── Day 6:   kvcache_compress_top.sv (AXI + FSM + CSR)
         └── Day 7:   Verilator lint — zero warnings
         GATE: make lint → 0 errors, 0 warnings

Week 3:  Verification
         ├── Day 1-2: tb_top.sv (10 tests, load golden vectors)
         ├── Day 3:   Verilator simulation — debug until all pass
         ├── Day 4:   Vivado xsim — verify same results
         ├── Day 5:   Waveform capture (key signals, all tests)
         ├── Day 6:   Fix any discrepancies between Verilator and xsim
         └── Day 7:   Final sim run, screenshot capture
         GATE: make sim → XX/XX PASS, ratio ≥ 8×, RMSE < 0.01

Week 4:  Synthesis + SoC
         ├── Day 1:   Synthesis at 400 MHz (make synth)
         ├── Day 2:   Fix timing violations if any
         ├── Day 3:   Block design with DMA (make block_design)
         ├── Day 4:   Debug block design connections
         ├── Day 5:   Bitstream generation
         ├── Day 6:   Firmware (fw/main.c)
         └── Day 7:   Final verification of all build targets
         GATE: make synth → WNS > 0 @ 400 MHz
         GATE: make block_design → bitstream generated

Week 5:  Documentation + Launch
         ├── Day 1-2: README.md, ARCHITECTURE.md
         ├── Day 3:   GitHub push, verify rendering
         ├── Day 4:   LinkedIn post draft
         ├── Day 5:   Collect stars, prep images
         ├── Day 6:   Post on Tuesday/Wednesday 8:30 AM
         └── Day 7:   Engage with comments
         GATE: GitHub live, LinkedIn posted
```

---

## DESIGN IMPLEMENTATION PATHWAY (Verified)

### Step-by-step with exact commands

```bash
# ============================================================
# SETUP (Day 0)
# ============================================================
mkdir -p ~/Projects/kvcache-compress-engine
cd ~/Projects/kvcache-compress-engine
mkdir -p model rtl tb vivado fw docs img
git init

# ============================================================
# PHASE 1: GOLDEN MODEL
# ============================================================
# Create model/golden_model.py
# Test with real Llama-3 KV-cache tensors
pip install torch numpy --break-system-packages
python model/golden_model.py
# Output: test_vectors/*.bin, accuracy report, compression report

make golden    # Wrapper: runs golden_model.py, checks RMSE < 0.01

# ============================================================
# PHASE 2: RTL DESIGN
# ============================================================
# Write all .sv files in rtl/
# Use VS Code with SystemVerilog extension

# Optional: Prototype quantizer in Vitis HLS first
# vitis_hls -f hls/run_hls.tcl
# This generates a C++ reference — NOT used as production RTL

# ============================================================
# PHASE 3: LINT
# ============================================================
make lint      # verilator --lint-only -Wall
               # Target: 0 errors, 0 warnings

# ============================================================
# PHASE 4: SIMULATION
# ============================================================
make sim       # verilator --binary → run
               # Target: all tests PASS
               # Target: COMPRESSION_RATIO ≥ 8×
               # Target: RMSE < 0.01

make wave      # gtkwave build/obj_dir/kvcache_compress.vcd

# ============================================================
# PHASE 5: VIVADO XSIM
# ============================================================
make xsim_gui  # vivado -mode gui -source vivado/sim.tcl
               # Run: restart; run 10us
               # Capture waveform screenshots

# ============================================================
# PHASE 6: SYNTHESIS
# ============================================================
make synth     # vivado -mode batch -source vivado/synth.tcl
               # Target: 400 MHz, WNS > 0
               # Reports: utilization, timing, power

# ============================================================
# PHASE 7: BLOCK DESIGN + BITSTREAM
# ============================================================
make block_design    # Full SoC + bitstream + XSA
make block_design_gui  # Open in Vivado GUI for inspection

# ============================================================
# PHASE 8: FIRMWARE (optional — only if targeting on-board demo)
# ============================================================
# Requires Vitis for cross-compilation
make firmware  # arm-none-eabi-gcc fw/main.c

# ============================================================
# PHASE 9: LAUNCH
# ============================================================
# Push to GitHub
git add .
git commit -m "COMPRESSION_RATIO = 8x — Hardware KV-Cache compression eliminates the memory wall in LLM inference"
git remote add origin https://github.com/taitashaw/kvcache-compress-engine.git
git push -u origin main
```

---

## Makefile Targets (Complete)

```makefile
# Build targets for KV-Cache Compression Engine
#   make golden         Phase 1: Python golden model
#   make lint           Phase 2: Verilator lint
#   make sim            Phase 3: Verilator simulation
#   make wave           View VCD waveforms
#   make xsim_gui       Phase 4: Vivado xsim
#   make synth          Phase 5: 400 MHz synthesis
#   make block_design   Phase 6: Full SoC + bitstream
#   make firmware       Phase 7: Cross-compile ARM firmware
#   make all            Phases 1-6
#   make clean          Remove all build artifacts
```

---

## KEY DIFFERENCES FROM SOFTMAX PROJECT

| Aspect | Softmax Project | KV-Cache Project |
|--------|----------------|-----------------|
| **Data interface** | AXI4-Lite only | AXI4-Lite + AXI4-Stream |
| **Data flow** | CSR register access | Streaming data pipeline |
| **DSP usage** | 0 (constant-folded) | 4-8 (real multipliers) |
| **BRAM usage** | 0 | 2-8 (score table, group buffer) |
| **Complexity** | ~900 lines RTL | ~1,300 lines RTL |
| **Block design** | Simple (PS + AXI-Lite) | Complex (PS + DMA + AXI-Stream) |
| **THE METRIC** | PERF_STALL_CYCLES = 0 | COMPRESSION_RATIO ≥ 8× |
| **Testbench** | 5 tests, 16 assertions | 10 tests, ~30 assertions |
| **Portfolio story** | "I solved the compute wall" | "I solved the memory wall" |

---

## THE LINKEDIN NARRATIVE

Project 1 (softmax): "The GPU's compute units are 256× faster than its special function unit. I proved that 550 LUTs of dedicated silicon eliminates the bottleneck."

Project 2 (KV-cache): "The GPU has 80 GB of memory but LLM inference needs 167 GB for KV-cache alone. I proved that hardware compression gives you 8× more effective memory at line rate."

Together: "I understand both sides of the transformer inference wall — compute and memory — and I've built hardware solutions for each, from RTL to bitstream."

This is the complete story that makes you unhirable at anything less than a senior/staff architect role at NVIDIA, Groq, Cerebras, or Tenstorrent.

---

## REFERENCES

- KIVI: A Tuning-Free Asymmetric 2bit Quantization for KV Cache (Liu et al., 2024)
- H2O: Heavy-Hitter Oracle for Efficient Generative Inference (Zhang et al., 2023)
- SnapKV: LLM Knows What You Are Looking For Before Generation (Li et al., 2024)
- StreamingLLM: Efficient Streaming Language Models with Attention Sinks (Xiao et al., 2023)
- KVQuant: Towards 10 Million Context Length via KV Cache Quantization (Hooper et al., 2024)
- FlashAttention-3 (Shah et al., 2024) — for context on the full attention pipeline
