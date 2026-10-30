# Live lab transcript summary (real `claude` v2.1.314 primary, FM_HOME=lab, plain clone of f902134)
Turn 1 "…PORTAL: page=abc123 task=lab-1" -> sidecar trailer_status=valid kind=page page_ids=[abc123] task_ids=[lab-1] outside=35, real prompt_id 3d3a03db-…
Turn 2 "Captain, shipshape." prompt f7edf9d7-… -> valid/none/outside 0
Turn 3 "Captain, shipshape." prompt fc901f26-… -> second distinct sidecar (valid/none/0)
Turn 4 "hello lab" -> missing/null/outside 9
Opt-out (config/portal-capture removed) turn ending "PORTAL: none" -> sidecar count stayed 4
Replay of turn-1 Stop payload from inside the lock-owning Claude session (bash mode) x3 -> count unchanged (dedup); same payload with new prompt_id -> +1; linked-worktree copy of hook -> no write
Sidecar dir chmod 555 during a real turn -> turn completed normally, no sidecar, no .capture.* temp left, log: "fm-portal-capture.sh:80: cannot create temporary sidecar"
prune with flag removed: 2 files aged 31d removed, 29d kept; KEEP_DAYS=28 removed the 29d file; KEEP_DAYS=abc -> "fm-portal-capture.sh:33: invalid FM_PORTAL_SIDECAR_KEEP_DAYS", nothing removed, no output, rc 0
crew-ledger tick (real fm-crew-ledger.sh + fm-crew-state.sh, fake tmux to avoid default server): title from Captain's intent (fenced decoy ignored), title null w/o brief, worktree from meta, current_state.since=20000 preserved at 20600/21200/21800
