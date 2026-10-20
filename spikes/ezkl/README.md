# EZKL spike: 16→32→5 MLP + Softmax → Halo2 proof → EVM verifyProof

Isolated from `contracts/` and `analysis/`. Artifacts in `out/` (≈1 GB, git-ignored).

## Reproduce

```bash
cd spikes/ezkl
uv sync                                   # ezkl 23.0.5, onnx, numpy, onnxruntime (no torch)
uv run python build_model.py              # model.onnx + input.json + cal.json
uv run python build_model.py --logits     # model_logits.onnx (no Softmax)
./run.sh fixed                            # settings→calibrate→compile→srs→setup→witness→prove→verify
./run.sh hashed                           # same with param_visibility=hashed
./run.sh fixed --logits                   # logits-only variant
.venv/bin/python pipeline.py evm --variant fixed && .venv/bin/python pipeline.py calldata --variant fixed
./onchain.sh fixed                        # anvil deploy + verifyProof (valid / tampered input / tampered output)
REUSABLE=1 .venv/bin/python pipeline.py evm --variant hashed && .venv/bin/python pipeline.py vka --variant hashed
./reusable.sh hashed                      # experimental reusable verifier + registerVka
```

Per-step wall time / peak memory: `out/<variant>_timing.log`.

## Results (Apple M5, 16 GB)

| variant | logrows | setup | prove | prove peak mem | pk | proof | verifier runtime | tx gasUsed |
|---|---|---|---|---|---|---|---|---|
| fixed + Softmax | 15 | 6.1 s | 8.9 s | 1.23 GB | 361 MB | 5152 B | 19,656 B | 794,589 |
| hashed + Softmax | 15 | 4.0 s | 5.8 s | 1.45 GB | 466 MB | 6048 B | 24,206 B (370 B under EIP-170) | 916,748 |
| fixed, logits only | 15 | 1.2 s | 1.6 s | 0.41 GB | 138 MB | — | 13,440 B | 552,951 |
| hashed, reusable verifier | 15 | — | — | — | — | 6048 B | 10,917 B (+ VKA 8.5 KB per call) | 1,204,063 |

solc 0.8.28 (generated `pragma ^0.8.0`), optimizer 200 runs, evm cancun.
