# Zero-Shot Detection Accelerator — Architecture Design

**Target:** Digilent Genesys 2 (Xilinx Kintex-7 **XC7K325T-2FFG900C**)
**Host CPU:** C-DAC VEGA RISC-V soft core (RV32, AXI4) in the same FPGA fabric
**Workload:** Prompt-conditioned zero-shot object detection
(YOLOE-26n-seg open-vocabulary detector + model2vec/potion text ranking)

---

## 1. Goal & functional spec

Given an **image** (already resident in DDR3) and a **text prompt** (over UART),
the system returns the **single best bounding box** whose class is (a) present in the
image and (b) the best semantic match to the prompt.

Reference algorithm (from `YOLO26N/main.py`):

1. `model2vec` embeds the prompt → 256-d L2-normalized vector.
2. Cosine similarity vs. 80 pre-computed COCO class embeddings → **ranked class list**.
3. YOLOE detector run with the ranked classes as the open-vocab text-prompt set;
   detections scored `score = (1/(rank+1)) * conf`.
4. Highest-scoring detection → bbox + label + score, drawn / returned.

**Design decision:** model2vec is *static* (token-embedding lookup + mean-pool + L2-norm).
It is ~20K MAC for the whole ranking step. It does **not** go on the accelerator — it
runs as VEGA software. The accelerator is dedicated to the **YOLOE convolutional network**,
which holds ~99% of the arithmetic.

---

## 2. Target platform budget (XC7K325T-2)

| Resource | Available | Notes |
|---|---|---|
| DSP48E1 | 840 | INT8 2-MAC packing (Xilinx WP486) → up to ~1600 INT8 MAC |
| BRAM36 | 445 (≈16 Mb) | weights (3.4 MB) do **not** fit on-chip → DDR-resident |
| LUT | 203,800 | |
| FF | 407,600 | |
| DDR3 SODIMM | 1 GiB, 32-bit | MIG, ~4–5 GB/s usable bandwidth |
| UART | USB-UART bridge | prompt in / result out |
| Ethernet / JTAG | RGMII PHY / JTAG-to-AXI | host→DDR image upload path |

Reserve ~40 DSP and ~20 BRAM for the MIG controller, VEGA core, and glue.

**Design ceiling: total device utilization ≤ 40% on every axis** (DSP/BRAM/LUT) — headroom
for timing closure, routing, and power on the K7-2. Binding limits: ≤336 DSP, ≤178 BRAM36,
≤81K LUT. The accelerator is sized to fit *under* these after VEGA+MIG overhead (see §6).

---

## 3. System block diagram

```
                  ┌──────── UART (USB) ──────── external host
                  │            prompt in / bbox+label+score out
                  ▼
        ┌───────────────────────┐
        │   C-DAC VEGA core      │  RV32IM, ~100 MHz
        │   - model2vec + rank   │
        │   - kick (1 START)     │
        │   - decode + postproc  │
        │   - UART driver        │
        └───────┬───────────────┘
                │ AXI4-Lite  (VEGA = master, ACC = slave)
                │  cmd / status / IRQ
        ┌───────▼───────────────────────────────────┐
        │              ACCELERATOR                    │
        │  ┌────────────┐  ┌──────────────┐          │
        │  │ cmd/status │  │  DMA engine  │          │
        │  │   regs     │  │  (2D strided)│          │
        │  └────────────┘  └──────┬───────┘          │
        │  ┌──────────────────────┴──────────┐       │
        │  │ on-chip SRAM (BRAM) tile buffers │       │
        │  │  ifmap / weight / psum / ofmap   │       │
        │  └──────────────────────┬──────────┘       │
        │  ┌────────────┐  ┌───────▼──────┐          │
        │  │ vector unit│◄─│ systolic INT8 │         │
        │  │ relu/quant │  │  16×32 array  │          │
        │  │ pool/add   │  │  (wt-stat.)   │         │
        │  └────────────┘  └──────────────┘          │
        └───────┬─────────────────────────────────────┘
                │ AXI4 (ACC = master)  burst R/W
        ┌───────▼──────────┐
        │  MIG  →  DDR3 1GB │  weights, fmaps, image, model2vec table
        └──────────────────┘
                ▲
                │  host→DDR image upload (JTAG-to-AXI or Ethernet/lwIP)
                └─────────────────────────────────────────────────────
```

Two clock domains: **AXI/control** (VEGA, ~100 MHz) and **compute** (systolic, 150–200 MHz),
crossed with async FIFOs at the DMA / register boundary. DDR/MIG has its own UI clock.

---

## 4. Compute partition (HW vs SW)

| Stage | Arithmetic | Placement | Rationale |
|---|---|---|---|
| Tokenize prompt (WordPiece, `vocab.txt`) | string ops | VEGA SW | sequential, tiny |
| model2vec embed: gather rows + mean + L2 | ~N·256 add | VEGA SW | memory-bound, trivial |
| Rank 80 COCO classes (cosine) | 80×256 MAC | VEGA SW | ~20K MAC, negligible |
| **YOLO26n conv backbone + neck + head** | **GMAC INT8** | **Accelerator** | dominant FLOPs |
| Detect decode + score `conf/(rank+1)` + pick | small | **VEGA SW** | irregular, runs parallel to YOLO |
| ~~NMS~~ | — | **none** | **YOLO26 is NMS-free** (end-to-end one-to-one head) |
| Result framing → UART | — | VEGA SW | I/O |

> **Option B — CPU scores.** The accelerator runs the whole network and writes **all
> detections to DDR** (the head layer's `out_addr`). The CPU reads that tensor and applies
> `score = conf/(rank+1)` to pick the best (or top-k) in software. Because model2vec only
> needs the prompt, it runs fully in parallel with YOLO — no ordering prerequisite, no
> hardware box-picker, no rank-weight/result registers. (An on-chip top-1 helper is possible
> but was dropped to keep the engines decoupled.)
>
> **YOLO26 is NMS-free**: end-to-end one-to-one assignment + anchor-free head emit final
> boxes directly, so decode is just threshold + top-k — no IoU suppression loop.

model2vec embedding table (BAAI bge tokenizer vocab ≈30.5K × 256, PCA-256) stored INT8
in DDR (~7.8 MB). 80 class embeddings pre-computed once at boot, kept in BRAM/scratch.

---

## 5. Accelerator microarchitecture

Re-targeted from the existing `tensor_accelerator` IP (UltraScale+/Versal) down to K7,
**sized to the ≤40% device ceiling**.

- **Systolic array:** 16×32 weight-stationary INT8 PEs = **512 MAC**.
  With 2-MAC/DSP packing → **256 DSP48E1** (~30% of 840).
- **Dataflow:** weight-stationary. Load 16×32 weight tile → stream activations →
  INT32 partial sums drain from bottom. Output-stationary accumulation across K-tiles.
- **Peak:** 512 MAC × 2 op × 200 MHz = **205 GOPS** (INT8).
  At a safe 150 MHz: ~154 GOPS. Enough for YOLO26n (~few GMAC) at interactive latency.
- **Vector / post unit:** 32–64 lane — requantize (INT32→INT8 with per-channel scale),
  bias add, ReLU/SiLU (LUT-approx), max-pool, residual add, concat.
- **DMA engine:** 2D strided descriptors for im2col-free conv tiling
  (channel-major weight fetch, line-buffered ifmap fetch, ofmap write-back).

### Conv tiling
Loop nest per layer: `for (oc_tile) for (ic_tile) for (oh,ow tile)`.
- Weight tile: 16(oc)×32(ic) loaded into array.
- Ifmap tile streamed from on-chip line buffer (refilled by DMA from DDR).
- Psum held on-chip in INT32 across ic_tiles; on last ic_tile → requant → ofmap kept
  **on-chip if it fits**, else spilled to DDR (see §5c residency).
- Stride/padding/kernel size are register-programmed per layer.

### 5b. Decode — done on the CPU (Option B, not in hardware)
The head post-process is trivial (NMS-free): threshold + `score = conf/(rank+1)` + argmax.
**It runs on VEGA**, reading the detection tensor the accelerator wrote to DDR. This keeps
model2vec and YOLO fully parallel (no rank-weight load before the head) and the hardware
simpler. An on-chip top-1 helper (~1K LUT streaming argmax) is possible if you ever want to
avoid the CPU readback, but it re-introduces an ordering constraint, so it is **not used**.

### 5c. On-chip feature-map residency
Keep inter-layer activations in BRAM whenever the tensor fits the tile buffers; only spill
to DDR when too large. For YOLO26n's small fmaps (esp. deeper stages) this **avoids the
write+read DDR round-trip per layer**, cutting both bandwidth and latency.

---

## 6. Resource budget (estimate)

| Block | DSP | BRAM36 | LUT |
|---|---:|---:|---:|
| Systolic 16×32 (packed INT8) | 256 | 6 | 20K |
| Vector/post unit (32-lane) | 16 | 6 | 12K |
| Decode helper (§5b) | 0 | 1 | 1K |
| DMA + AXI master (descriptor-chained) | 0 | 14 | 11K |
| On-chip tile SRAM (ifmap/wt/psum/ofmap + residency) | 0 | 80 | 4K |
| AXI4-Lite slave + cmd/status | 0 | 2 | 5K |
| MIG (DDR3) | 8 | 18 | 14K |
| VEGA core + UART + bus | 4 | 22 | 12K |
| **Total** | **~284 / 840 (34%)** | **~149 / 445 (33%)** | **~79K / 204K (39%)** |

All axes **≤40%**. LUT is the binding constraint (VEGA softcore dominates glue) — keep the
VEGA build minimal (RV32IM, no FPU). If headroom proves larger after impl, the array can
grow to 24×32 (768 MAC, 384 DSP = 46%) only if the 40% ceiling is relaxed.

---

## 7. DDR3 memory map (1 GiB)

| Region | Base (example) | Size | Contents |
|---|---|---|---|
| Code/data (VEGA) | 0x0000_0000 | 64 MB | bare-metal app, stack, heap |
| Image buffer | 0x0400_0000 | 4 MB | 640×640×3 input (host-loaded) |
| Weights (INT8) | 0x0500_0000 | 8 MB | YOLOE conv weights + bias/scale |
| Feature-map ping/pong | 0x0600_0000 | 32 MB | inter-layer activations |
| model2vec emb table | 0x0900_0000 | 8 MB | static token embeddings (INT8) |
| Result / scratch | 0x0A00_0000 | 4 MB | detections, decode scratch |

Addresses are placeholders — finalize against MIG aperture and VEGA linker script.

---

## 8. AXI interfaces

### 8a. AXI4-Lite slave (VEGA → accelerator control)
Register map (offset from accelerator base):

| Offset | Reg | Access | Description |
|---|---|---|---|
| 0x00 | CTRL | R/W | bit0 START, bit1 IRQ_EN, bit2 SOFT_RST |
| 0x04 | STATUS | R | bit0 BUSY, bit1 DONE, bit2 ERR |
| 0x08 | LAYER_CFG0 | R/W | kernel, stride, pad, act-type |
| 0x0C | LAYER_CFG1 | R/W | IC, OC |
| 0x10 | LAYER_CFG2 | R/W | IH/IW |
| 0x14 | LAYER_CFG3 | R/W | OH/OW |
| 0x18 | WT_ADDR | R/W | DDR weight base for this layer |
| 0x1C | IN_ADDR | R/W | DDR ifmap base |
| 0x20 | OUT_ADDR | R/W | DDR ofmap base |
| 0x24 | BIAS_ADDR | R/W | DDR bias/scale base |
| 0x28 | REQUANT | R/W | requant shift / zero-point |
| 0x2C | IRQ_ACK | W | clear DONE/ERR |
| 0x30 | DESC_BASE | R/W | DDR base of layer descriptor list (chained mode) |
| 0x34 | DESC_COUNT | R/W | number of layers in list |

No RESULT or rank-weight registers (Option B): detections live in DDR, scored by the CPU.

**Two modes.** *Single-layer* (bring-up): VEGA writes one layer's cfg, START, waits DONE,
repeats. *Chained* (full-net, default): VEGA writes `DESC_BASE`/`DESC_COUNT` once, one
START; accelerator self-walks the list and writes every layer's output (incl. the head's
detection tensor) to DDR. VEGA reads detections from DDR after the single DONE.

Descriptor format in DDR (per layer): the same fields as LAYER_CFG0..3 + WT/IN/OUT/BIAS
addrs + REQUANT, 64-byte aligned, `next` implied by index.

### 8b. AXI4 master (accelerator → DDR3)
- Full AXI4, burst length up to 256, data width 128-bit (16 B/beat).
- Independent read (weights+ifmap) and write (ofmap) channels.
- Outstanding transactions ≥4 to hide DDR latency.

---

## 9. End-to-end sequence

```
VEGA: image → DDR ;  start model2vec (prompt → ranked classes)   [parallel]
VEGA: build descriptor list in DDR, write DESC_BASE/COUNT, set START (single kick)
ACC : self-walk all layers — DMA wt+ifmap → mac_tile → requant →
       fmap on-chip (or DDR spill) → … → head → write detection tensor → DDR
ACC : raise one DONE IRQ
VEGA: read detections from DDR, score conf/(rank+1) with model2vec ranks, pick best
VEGA ──UART──► host  (optional functionality check)
```

**Full-net = one round-trip.** VEGA kicks once and sleeps on a single DONE IRQ. model2vec
overlaps the YOLO run entirely; scoring happens after DONE on the DDR detections (Option B).

### 9b. Minimizing accelerator ↔ CPU traffic

The slow RV32 softcore must stay off the inner loop. Five levers, applied here:

1. **Descriptor-chained DMA.** Whole-network layer list (cfg+addrs per layer) is built in
   DDR by VEGA *once* at boot (graph is static). Accelerator self-walks it. Per-layer
   register pokes drop from N×~10 writes to **zero** during inference.
2. **Single kick / single IRQ.** One START, one DONE for the entire net — not per layer.
   No polling, no per-layer handshake. VEGA can even sleep (WFI) until DONE.
3. **Op fusion in the vector unit.** conv → bias → requant → activation (SiLU) → pool →
   residual-add are fused in one pass. No intermediate DDR round-trip between sub-ops.
4. **On-chip fmap residency (§5c).** Activations stay in BRAM across layers when they fit;
   DDR touched only for weights and the few oversized maps. Slashes AXI-master traffic.
5. **CPU scoring in parallel (Option B).** Detections are written to DDR; VEGA scores them
   *after* DONE while model2vec already ran *during* the YOLO pass. No result registers, no
   mid-run rank-weight load — the two engines are fully decoupled.

Net effect: per-inference VEGA↔ACC control = **1 START write + 1 IRQ + a few STATUS reads**.
Detections move accelerator→DDR→CPU; everything else is accelerator↔DDR only.

---

## 10. Quantization

- INT8 weights/activations, INT32 accumulate (matches `yoloe-26n-seg_int8.onnx`).
- Per-channel weight scale, per-tensor activation scale (export from the ONNX QDQ model).
- Requant in vector unit: `int8 = clamp(round(acc * M) >> shift) + zp`, fixed-point `M`.
- SiLU/sigmoid via piecewise-linear LUT (YOLO uses SiLU); verify accuracy vs. ONNX golden.

---

## 11. UART protocol (host ↔ VEGA)

Framed, binary, 115200 8N1 (image is **not** sent over UART — it goes to DDR).

Host → VEGA:
```
0xA5 | LEN(2) | prompt UTF-8 bytes | CRC8
```
VEGA → host:
```
0x5A | label_id(1) | x1(2) y1(2) x2(2) y2(2) | score_q8(2) | CRC8
0x5E | err_code(1)                                          # no match / error
```

---

## 12. Bring-up & verification plan

1. **Unit:** reuse `tensor_accelerator` cocotb TBs for mac_pe / systolic / dma after K7 resize.
2. **Single conv golden test:** one YOLOE layer, compare accelerator vs. ONNXRuntime INT8 golden vectors.
3. **AXI loopback:** VEGA writes regs, DMA round-trips a DDR buffer.
4. **Layer-by-layer:** walk the full net, dump each ofmap, diff vs. golden.
5. **Full pipeline:** image in DDR + prompt over UART → bbox out; compare to `main.py` reference.
6. **Resource/timing:** Vivado impl on XC7K325T-2, close timing at target clock.

---

## 13. Risks & open items

| Risk | Mitigation |
|---|---|
| YOLOE-26n has open-vocab text-PE path (not pure CNN) | Map text-PE matmul to accelerator or VEGA; confirm INT8 export covers it |
| Timing closure of 16×32 INT8 @200 MHz on K7-2 | Fall back to 150 MHz / add pipeline regs; budget already ≤40% |
| VEGA softcore too slow on inner loop | Descriptor-chained DMA + single kick → VEGA off critical path; scoring runs after DONE, parallel to model2vec (§9b) |
| SiLU LUT accuracy | Tune breakpoints; validate mAP vs. FP reference |
| DDR bandwidth bound on large fmaps | Tile to maximize weight reuse; depthwise layers are BW-bound — fuse where possible |
| WordPiece tokenizer on bare-metal RV32 | Port minimal greedy WordPiece; preload vocab hash table in DDR |

---

## 14. Next steps

1. Profile `yoloe-26n-seg_int8.onnx`: per-layer shapes, MAC count, op types → schedule table.
2. Re-target `tensor_accelerator` RTL params to 16×32 + DSP packing for XC7K325T (≤40%).
3. Build Vivado block design: VEGA + accelerator + MIG + UART + Ethernet/JTAG-to-AXI.
4. Write VEGA bare-metal: model2vec, descriptor builder, DDR detection scoring, UART, driver (§8). No NMS.
5. Execute §12 verification ladder.
