# TOKEN_USE Archive — Historical Session Data

> **Note:** This file is for historical reference only and is not read during routine tasks.
> It contains session analysis tables archived from TOKEN_USE.md to keep that document concise.

---

## 3. Session Analysis

### 3.1 Latest Session Data (2026-04-05, n=10)

| Session ID | Model | LLM Calls | Input Tok | Output Tok | Cache Read Tok | Cache Create Tok | Duration | Category |
|------------|-------|-----------|-----------|------------|----------------|------------------|----------|----------|
| 7ae06422 | sonnet | 1 | 205 | 18,160 | 7,099,886 | — | 445s | **Extreme** analysis |
| a1724034 | sonnet | 1 | 97 | 17,591 | 3,689,818 | — | 475s | Heavy analysis |
| c5152d56 | sonnet | 49 | 67 | 1,675 | 1,460,169 | 82,748 | 190s | Heavy multi-turn |
| 819a72dc | **opus** | 1 | 22 | 2,810 | 642,387 | — | 93s | Medium task |
| 0d89bcf8 | sonnet | 1 | 28 | 3,554 | 675,666 | — | 148s | Medium task |
| 7cb87709 | sonnet | 17 | 27 | 193 | 539,379 | — | 61s | Medium multi-turn |
| f4f34625 | sonnet | 1 | 13 | 4,593 | 332,402 | — | 107s | Medium task |
| eef6e3f9 | sonnet | 1 | 12 | 2,278 | 286,858 | — | 70s | Light task |
| eebf7ed9 | sonnet | 1 | 4 | 70 | 43,659 | — | 7s | DONE-call |
| 73cb649b | sonnet | 1 | 4 | 72 | 22,152 | — | 7s | DONE-call |

### 3.2 Turn-Level Analysis: Session c5152d56 (49 turns)

This session provides the first detailed turn-level data. Context growth pattern:

| Turn Range | Avg Cache Read/Turn | Avg Cache Create/Turn | Avg Output/Turn | Phase |
|------------|--------------------|-----------------------|-----------------|-------|
| 1–5 | 8,861 | 15,423 | 17 | Cache warmup; 3 turns at 0 cache read |
| 6–10 | 25,022 | 1,387 | 54 | Tool calls; cache stabilized |
| 11–20 | 29,086 | 651 | 38 | Editing; steady growth |
| 21–30 | 32,424 | 571 | 39 | More edits; context ~32k |
| 31–40 | 34,975 | 904 | 43 | Tests + fixes; context ~35k |
| 41–49 | 41,195 | 1,033 | 42 | Final commits; context peaked at 43k |

**Key insight:** Context grew 95% (22k → 43k) over 49 turns. Cumulative cache reads: 1,460,169 tokens. At Sonnet pricing ($0.30/MTok): ~$0.44. This confirms the ≤8 round-trip budget is critical — session c5152d56 at 49 turns consumed 8× more cache than a typical 6-turn task.

### 3.3 Model Usage Improvement

| Period | Sessions | Opus % | Avg Cache Tok | Avg Output Tok |
|--------|----------|--------|--------------|----------------|
| 2026-04-03 | 10 | 0% | 233,350 | 5,032 |
| 2026-04-04–05 (prior) | 5 | 60% | 1,721,050 | 9,402 |
| 2026-04-05 (this) | 10 | 10% | 1,479,238 | 5,100 |

Opus usage dropped from 60% to 10%. The remaining Opus session (819a72dc, 642k cache) cost ~$0.96 vs ~$0.19 at Sonnet rates — a $0.77 premium for a medium-complexity task.

### 3.4 Session Size Distribution

| Category | Count | Avg Cache Tok | Avg Duration | Est. Cost (Sonnet) |
|----------|-------|--------------|-------------|-------------------|
| DONE-call (<50k cache) | 2 | 32,906 | 7s | $0.01 |
| Light (<300k) | 1 | 286,858 | 70s | $0.09 |
| Medium (300k–700k) | 4 | 547,459 | 102s | $0.16 |
| Heavy (>700k) | 3 | 4,083,291 | 370s | $1.22 |

Heavy sessions (30% of total) consume 83% of all cache tokens.
