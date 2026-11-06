# DeepCABAC — VHDL Decoder

## Overview

Hardware implementation of a **Context-Adaptive Binary Arithmetic Coding (CABAC) decoder** for losslessly decoding compressed, quantized neural-network weights.

The decoder is implemented in **VHDL**, with a target throughput of **one symbol per clock cycle**, supporting up to **16 bins per symbol**.

## Architecture

The design consists of nine RTL modules:

| Module | Function |
|---|---|
| `cabac_top` | Top-level integration |
| `fifo` | Encoded-data buffering |
| `intermediate_storage` | Bit reservoir |
| `cabac_split_engine` | Arithmetic split calculation |
| `decoder_step` | Arithmetic decoding |
| `decoder_branch_renorm` | Branch selection and renormalization |
| `context_step` | Context-model updates |
| `debin_step` | Symbol reconstruction |
| `cabac_types_pkg` | Shared types |

## Verification Results

Functional verification was performed using **Cadence Xcelium**, comparing decoded symbols against reference neural-network weights.

| Dataset | FIFO Depth | Storage | Result |
|---|---:|---:|---|
| BERT | 1 | 64 bits | PASS — 2,359,296 symbols |
| Swin | 1 | 64 bits | PASS — 1,048,576 symbols |
| MobileNet | 32 | 256 bits | FAIL — bit-shortage stall |
| MobileNet | 64 | 256 bits | FAIL — bit-shortage stall |

Both MobileNet configurations passed the 600,000-symbol checkpoint before stalling at **6,066,465 ns**. No decoded-value mismatch was reported before the stall.

## Repository Structure

```text
CABAC/
├── RTL/                # 9 VHDL modules
├── Testbenches/
│   ├── BERT/FIFO1_IS64/
│   ├── Swin/FIFO1_IS64/
│   └── MobileNet/
│       ├── FIFO32_IS256/
│       └── FIFO64_IS256/
├── README.md
└── .gitignore
```

Each testbench directory contains the VHDL testbench, `run.tcl`, and simulation log.

## Tools

- **VHDL** — Hardware implementation
- **Cadence Xcelium** — RTL simulation and verification
- **Python** — Reference model and dataset preparation

