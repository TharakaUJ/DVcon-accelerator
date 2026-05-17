# DVCon Accelerator

FPGA-based YOLO Winograd accelerator research and RTL prototype.

## Project Links

- Model repository: [Main model (software approach)](https://github.com/BimsaraU/DVCon-SittingDucks)
- Relevant project links:
  - [K-graph approach](https://github.com/thilakshan2003/DVCON-kgraph_for_coco)
  - <add link here>
  - <add link here>

## Project Summary So Far

Project Status: FPGA-Based YOLO Winograd Accelerator

Current Milestone Achieved:
Designed and verified a scalable $4 \times 4$ systolic array core for independent matrix operations.

Immediate Next Step:
Validated a single-tile Winograd $F(2,3)$ proof of concept, executing $U \odot V$ element-wise multiplication on the array hardware.

Next Steps:
- Line buffer subsystem for streaming $4 \times 4$ tiles from feature maps.
- Zero-DSP transform blocks for $B^TdB$ and $AfA^T$.
- Tiling and memory optimization for deeper YOLO channel sizes.

Target Objective:
Complete single-layer hardware execution and compare Winograd vs. standard spatial convolution for throughput and energy.

## Existing Work

I started from a fixed-point PE and built a 4x4 systolic array around it. The PE handles the multiply-accumulate step, and the array organizes those PEs into a reusable compute block for matrix-style operations.

The Winograd path sits on top of that hardware. It uses the array for the element-wise product stage, with separate input and weight transforms around it. I have a solid understanding of how CNN convolution maps onto systolic arrays and how Winograd fits into that flow, but a few integration details are still being refined.

## Architecture Notes

```mermaid
graph TD
    %% Define Data Structures (Conceptual Classes)
    subgraph InputData["Input Feature Map (C x H x W)"]
        FM[Pixel vector: ch0, ch1, ch2, ch3 at y,x]
    end

    subgraph WeightData["Kernels (K x C x 3x3)"]
        K0[Kernel 0, ch0-3, 3x3]
        K1[Kernel 1, ch0-3, 3x3]
        K2[Kernel 2, ch0-3, 3x3]
        K3[Kernel 3, ch0-3, 3x3]
    end

    %% Define the Systolic Array (Component Diagram)
    subgraph SystolicArray["4x4 Weight-Stationary Array Core"]
        PE00[PE 0,0]
        PE01[PE 0,1]
        PE10[PE 1,0]
        PE11[PE 1,1]
        %% ... others implied
    end

    %% Define Mapping Flow
    %% Data flowing into the left (Data Stationary or Output Stationary assumed for simplification of visualization here)
    FM_desc["Spatially serial\nbut Channel Parallel\n(ch0,ch1,ch2,ch3)"]
    FM --> FM_desc
    FM --> PE10
    FM_desc --> PE00

    %% Weights stationary inside
    K0 -.-> PE00
    K1 -.-> PE01
    K2 -.-> PE10
    K3 -.-> PE11

    %% Output
    PE01 -->|Partial Sum| Out0
    PE11 -->|Partial Sum| Out1

    %% Notes
    style SystolicArray fill:#f9f,stroke:#333,stroke-width:2px
    style K0 fill:#ff9,stroke:#333
    style K1 fill:#ff9,stroke:#333
    style K2 fill:#ff9,stroke:#333
    style K3 fill:#ff9,stroke:#333

```

    **Diagram 1 — Channel-to-hardware mapping:** A 2D 4×4 systolic array maps channel vectors (C) across PEs to compute multiple output filters (K) in parallel. Weights stay stationary while activations stream through the array.


```mermaid
graph LR
    %% Data sources
    subgraph SpatialDomain [Spatial Domain]
        G_mat["Weights 'g'\n3x3"]
        D_tile["Input Tile 'd'\n4x4"]
    end

    %% Transform Stage
    subgraph TransformStage [Phase 1: Transformations]
        U_trans["Weight Transform:\nU = GgG^T\n(Pre-computed off-chip)"]
        V_trans["Input Transform:\nV = B^TdB\n(On-chip Line Buffers + LUTs)"]
    end

    %% Winograd Domain (Hadamard)
    subgraph WinogradDomain [Phase 2: Winograd Domain]
        Hadamard["Element-wise Product ⊙\nU ⊙ V = M\n(16 Multiplications)"]
    end

    %% Inverse Transform
    subgraph InverseStage [Phase 3: Inverse Transform]
        Y_trans["Output Transform:\nY = A^TMA\n(On-chip LUTs)"]
    end

    %% Output
    subgraph OutputDomain [Final Output]
        Y_final["Output 'Y'\n2x2"]
    end

    %% Connections
    G_mat -->|Off-line| U_trans
    D_tile -->|Streaming| V_trans

    U_trans -->|4x4 Matrix U| Hadamard
    V_trans -->|4x4 Matrix V| Hadamard

    Hadamard -->|4x4 Matrix M| Y_trans
    Y_trans --> Y_final

    %% Styling
    style Hadamard fill:#f96,stroke:#333,stroke-width:2px
    style U_trans fill:#ddd
    style V_trans fill:#ddd
```

    **Diagram 2 — Winograd transform flow:** We pre-transform weights (U) and transform input tiles (V), perform 16 element-wise multiplications (U ⊙ V), then inverse-transform to produce the final 2×2 output. Transforms use simple constants (1, −1, 2), making them cheap to implement in logic.


```mermaid
graph TD
    %% The Key Concept: Transformed Volumes
    subgraph WinogradInputVolumes [Winograd Transformed Volumes]
        V_Vol["Transformed Input V:\n16 Coordinates x C Channels"]
        U_Vol["Transformed Weights U:\n16 Coordinates x C Channels x K Filters"]
    end

    %% The Hardware Core
    subgraph HardwareExecution [FPGA Architecture]
        subgraph SystolicCore [4x4 Systolic Array Core]
            PE00["PE 0,0\n(Coord 0,0)"]
            PE01["PE 0,1\n(Coord 0,1)"]
            PE10["PE 1,0\n(Coord 1,0)"]
            PE11["PE 1,1\n(Coord 1,1)"]
            %% PEs for all 16 coordinates implied
        end
    end

    subgraph OutputM [Partial Outputs M]
        M00["M[0,0]"]
        M01["M[0,1]"]
        M10["M[1,0]"]
        M11["M[1,1]"]
    end

    %% Highlighting the Channel Summation
    V_label["Channel Vector (stream)\nV[i,j, ch0...C]"]
    U_label["Channel Vector (stationary)\nU[k,i,j, ch0...C]"]
    V_Vol --> V_label
    U_Vol --> U_label
    V_label --> SystolicCore
    U_label --> SystolicCore

    PE00 ==>|Summation over C| M00
    PE01 ==>|Summation over C| M01
    PE10 ==>|Summation over C| M10
    PE11 ==>|Summation over C| M11

    %% Connection to Final Step
    OutputM -->|4x4 Tile of M| InverseTransform["Inverse Transform A^TMA"]

    %% Note defining the PE operation
    Note1["PE[i,j] core loop:\nM[i,j] += U[k,c,i,j] * V[c,i,j]\nfor c=0 to C-1"]

    %% Styling
    style SystolicCore fill:#f9f,stroke:#333
    style Note1 fill:#fff,stroke-dasharray: 5 5
    style M00 fill:#bfb
    style M01 fill:#bfb
```

    **Diagram 3 — Channel summation on the array:** Each Winograd tile coordinate (i,j) is computed by summing per-channel products across C: $\\mathrm{Result}_{i,j}=\\sum_{c} U_{i,j,c}\\cdot V_{i,j,c}$. The 16 coordinates are independent and map directly to PEs for parallel accumulation.


## Simulation Screenshots


![Systolic array TB](./images/simulation%20systolic%20array%20tb.png)

## Existing Commands

```bash
make sim
make wave
make lint
make clean
```

## Notes

- The current RTL is still a work in progress.
- Some naming and integration details are still being aligned.
- The goal is to keep the benchmark small, clear, and easy to compare against standard convolution.