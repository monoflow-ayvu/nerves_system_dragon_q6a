# AGENTS.md

## VPU: Gen1/venus is debug-only, NEVER a fallback

The legacy `venus` driver + Gen1 firmware (`qcom/vpu/vpu20_p1.mbn`) on the
Dragon Q6A is **utterly broken for production**: it wedges at the driver
level after some encode sessions and only a full reboot recovers it.
Treat "VPU on venus" as **identical to no VPU at all**. CPU/software
transcoding is also non-viable on this board (too slow, too much CPU).

Hard rules:

- The ONLY acceptable VPU path is the **iris driver + Gen2 firmware**
  (`qcom/vpu/vpu20_p1_gen2_s6.mbn`, patches/linux/0001+). Do not ship,
  propose, or "temporarily" keep a venus-based build as the answer.
- Venus/Gen1 builds (e.g. v0.10.2) exist **only** as debugging/bisect
  sessions to isolate faults in the iris path. Never present one as a
  fix, rollback target, or steady state.
- Do not remove the venus guard logic's intent (iris owns the
  `qcom,sc7280-venus` compatible when enabled) and do not re-add a
  Gen1 fallback in the iris firmware-load path — Gen2 must work, not
  degrade.

Context: docs/BOARD_QUIRKS.md §11; /tmp/vpu-gen2-iris-evaluation-task.md
(app-team task doc) has the failure signature and validation plan.
