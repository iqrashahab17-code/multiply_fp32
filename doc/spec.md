# fmultiplier — FP32 Multiplier (Handshake, Multi-Cycle, IEEE-754)

## Overview
`fmultiplier` is a **multi-cycle** single-precision floating-point multiplier that accepts one operation at a time using a **valid/out_valid** handshake. Internally it runs a staged pipeline controlled by a small FSM (`counter`) and produces a 32-bit IEEE-754 binary32 result.

This design targets:
- **Bit-accurate results for normal FP32 numbers** (typical IEEE-754 behavior with round-to-nearest-even),
- Deterministic latency (fixed number of cycles from `valid` to `out_valid`),
- The design behaves as: z = a * b
- z, a, and b are single precision 32-bit IEEE-754 numbers

---

## Interface

### Ports
| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk`       | in  | 1     | Clock |
| `rst`       | in  | 1     | Async reset (posedge) |
| `valid`     | in  | 1     | **1-cycle start pulse**; accepted only when not busy |
| `a`         | in  | 32    | Operand A (FP32 bits) |
| `b`         | in  | 32    | Operand B (FP32 bits) |
| `z`         | out | 32    | Result (FP32 bits) |
| `out_valid` | out | 1     | **1-cycle pulse** when `z` is updated/valid |

### Handshake contract
- When `busy==0`, a high `valid` on a rising edge **starts** an operation:
  - `a` and `b` are **registered** into internal regs `a_r` and `b_r`.
  - The FSM begins at `counter = 1`.
- While `busy==1`, new `valid` pulses are **ignored**.
- When the operation completes:
  - `z` is updated,
  - `out_valid` pulses high for 1 clock cycle,
  - `busy` is cleared.

---

## Latency and Throughput

### Latency
- Fixed latency of **7 stages**.
- The operation begins at stage `counter=1` and completes at `counter=7`.
- `out_valid` asserts on the cycle where stage 7 packing finishes.
- **`out_valid` occurs exactly 7 clock cycles after the start edge** (the clock edge where `valid` was sampled when idle).

### Throughput
- **Not pipelined** (single-issue).
- Max throughput is **1 result per 7 cycles** (assuming `valid` is asserted only when idle).

---

## Internal Data Model (IEEE-754 binary32)
For each operand:
- `sign` = bit 31
- `exp`  = bits 30:23 (biased exponent)
- `mant` = bits 22:0 (fraction)

Internal signals:
- `a_s, b_s, z_s`: sign bits
- `a_e, b_e, z_e`: signed exponent in unbiased domain (stored as 10-bit regs, used with $signed)
- `a_m, b_m, z_m`: mantissas extended to 24-bit with hidden 1 when applicable
- `product`: **48-bit raw product** of mantissas (24-bit * 24-bit)
- `guard_bit`, `round_bit`, `sticky`: rounding support bits for RNE

---

## FSM / Pipeline Stages

The FSM is controlled by `busy` and a `counter` (stage number 1..7). All stage actions are performed inside a single sequential always block using `case(counter)`.

### Stage 1 — Unpack
- Extract mantissas into 24-bit regs (initially `{1'b0, frac}`).
- Convert biased exponent into unbiased form: exp - 127.
- Capture signs.

### Stage 2 — Special classification + denormal setup
- Checks operand classes using `a_is_nan`, `a_is_inf`, `a_is_zero`, etc.
- For normal operation:
  - If exponent is nonzero -> sets implicit leading 1: `a_m[23] = 1`.
  - If exponent is zero (subnormal) -> forces exponent to -126.

### Stage 3 — Input normalization (lightweight)
- If mantissa MSB is not set, shift left and decrement exponent.
- For strictly normal inputs, this typically does nothing.

### Stage 4 — Multiply core (Modified)
- Compute result sign: `z_s = a_s ^ b_s`
- Exponent add: `z_e = a_e + b_e`
- Mantissa product: `product = a_m * b_m`
  - *Change Note:* Eliminated the `*4` shift scaling. The core now evaluates a raw, un-truncated 48-bit product array to prevent bit-alignment misalignment.

### Stage 5 — Dynamic Mantissa Extraction & Alignment (Modified)
Instead of static hardcoded indexing, the selection window slides dynamically depending on whether a MSB overflow carry occurred at bit 47:

* **Case A: Product Carry-Out Present (`product[47] == 1`)**
  - `z_m = product[47:24]`
  - `guard_bit = product[23]`
  - `round_bit = product[22]`
  - `sticky = OR(product[21:0])`
  - Exponent compensation: `z_e = z_e + 1`

* **Case B: No Product Carry-Out (`product[47] == 0`)**
  - `z_m = product[46:23]`
  - `guard_bit = product[22]`
  - `round_bit = product[21]`
  - `sticky = OR(product[20:0])`
  - Exponent compensation: `z_e = z_e` (unchanged)

### Stage 6 — Normalize + Round-to-Nearest-Even (RNE) (Modified)
1. **Underflow alignment** toward exponent -126:
  - Computes shift amount `sh = (-126 - z_e)` when `z_e < -126`.
  - Shifts mantissa right and accumulates shifted-out bits into `sticky`.
2. **Normalize** if MSB missing.
3. **RNE rounding**:
  - If `guard_bit == 1` and `(round_bit || sticky || z_m[0])` then increment mantissa: `z_m = z_m + 1`.
  - **Handles carry-out from rounding:** If rounding overflows the 24-bit mantissa, normalize the fraction back by setting `z_m = 24'h800000` and increment the exponent: `z_e = z_e + 1`.

### Stage 7 — Pack
- For normal path:
  - Pack sign, biased exponent (z_e + 127), and fraction `z_m[22:0]`.
  - If exponent indicates overflow -> output INF.
  - If exponent indicates exact denorm boundary -> force exponent field to 0.
- Asserts `out_valid` for one cycle and clears `busy`.

---

## Assumptions & Constraints
- Inputs: exp in [1..254] (no zeros/subnormals, no inf/nan)

---

## Verification Notes
Recommended testbench behavior for this handshake design:
- Drive `a/b` and pulse `valid` **synchronously** on clock edges.
- Wait for `out_valid` before sampling `z`.
- Generate only normal operands.