#!/usr/bin/env python3
"""
feature_collector.py
Shared feature collector producing the consolidated 36-feature view:
  - ftrace function_graph snapshot -> function frequency counts for selected keys
  - lightweight call-graph parsing -> graph features: betweenness, clustering
  - process-scoped resource counters (CPU%, RSS, VMS, IO counters)

Notes:
  * Keys file (ftrace_keys.json) may be strict JSON list OR a loose YAML-like list; both accepted.
  * Graph metrics use a lightweight implementation (no external deps).
"""
from __future__ import annotations
import json, re, psutil
from pathlib import Path
from collections import Counter, defaultdict
from typing import Dict, Set, Tuple, List

# Tracefs locations
FTRACE_TRACE  = Path("/sys/kernel/tracing/trace")
FUNC_AT_END   = re.compile(r'([A-Za-z0-9_]+)\(\);?\s*$')
PID_RE        = re.compile(r'-([0-9]+)\s')  # matches "comm-1234  [..]"

# -------------- tolerant key loader ----------------
def load_keys(keys_path: str | Path) -> Set[str]:
    txt = Path(keys_path).read_text()
    # strict JSON list
    try:
        data = json.loads(txt)
        if isinstance(data, list):
            return {str(x).strip() for x in data if str(x).strip()}
    except Exception:
        pass
    # tolerate YAML bullets / comments
    ks: Set[str] = set()
    for line in txt.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("-"):
            line = line[1:].strip()
        line = re.sub(r'^[\'"]|[\'"],?$', "", line)
        if line:
            ks.add(line)
    return ks

# -------------- graph feature helpers --------------
def graph_features_from_sequence(seq: List[str], betw_k: int = 32) -> Dict[str, float]:
    """
    Build a directed graph from a flat function sequence (u->v edges for consecutive pairs).
    Compute:
      - betweenness (approx., source-sampled Brandes on up to betw_k sources)
      - average clustering coefficient (approx., local triangle rate)
    Returns {"betweenness": <float>, "clustering": <float>}
    """
    # nodes & adjacency
    nodes: Set[str] = set(seq)
    if not seq:
        return {"betweenness": 0.0, "clustering": 0.0}
    adj = defaultdict(set)   # u -> {v}
    radj = defaultdict(set)  # v -> {u}
    for i in range(len(seq) - 1):
        u, v = seq[i], seq[i+1]
        if u != v:
            adj[u].add(v)
            radj[v].add(u)

    V = list(nodes)
    # --- approximate betweenness centrality
    import random, math, collections
    sources = V if len(V) <= betw_k else random.sample(V, betw_k)

    def brandes_from_source(s: str) -> Dict[str, float]:
        # Unweighted shortest paths (BFS)
        S = []  # stack
        P = defaultdict(list)
        sigma = dict((v, 0.0) for v in V)
        d = dict((v, -1) for v in V)
        sigma[s] = 1.0
        d[s] = 0
        Q = collections.deque([s])
        while Q:
            v = Q.popleft()
            S.append(v)
            for w in adj[v]:
                if d[w] < 0:
                    Q.append(w); d[w] = d[v] + 1
                if d[w] == d[v] + 1:
                    sigma[w] += sigma[v]
                    P[w].append(v)
        delta = dict((v, 0.0) for v in V)
        while S:
            w = S.pop()
            for v in P[w]:
                if sigma[w] > 0:
                    delta[v] += (sigma[v] / sigma[w]) * (1.0 + delta[w])
        return delta  # dependency scores per node

    Cb = dict((v, 0.0) for v in V)
    for s in sources:
        dep = brandes_from_source(s)
        for v, sc in dep.items():
            if v != s:
                Cb[v] += sc
    # normalize by number of sources
    if sources:
        for v in V:
            Cb[v] /= float(len(sources))

    betweenness = float(sum(Cb.values()) / max(1, len(V)))

    # --- approximate clustering (directed -> undirected view)
    und = defaultdict(set)
    for u in adj:
        for v in adj[u]:
            und[u].add(v); und[v].add(u)
    tri_sum = 0.0
    valid = 0
    for u in V:
        nu = list(und[u])
        k = len(nu)
        if k < 2:
            continue
        valid += 1
        # count triangles among neighbors
        links = 0
        for i in range(k):
            ui = nu[i]
            for j in range(i+1, k):
                uj = nu[j]
                if uj in und[ui]:
                    links += 1
        # maximum possible links among k neighbors
        max_links = k * (k - 1) / 2.0
        tri_sum += (links / max_links) if max_links > 0 else 0.0

    clustering = float(tri_sum / valid) if valid > 0 else 0.0
    return {"betweenness": betweenness, "clustering": clustering}

# -------------- main collector ---------------------
class Collector:
    def __init__(self, keys_path: str | Path):
        self.keys = load_keys(keys_path)

    def _read_trace_snapshot(self) -> str:
        try:
            return FTRACE_TRACE.read_text(errors="ignore")
        except Exception:
            return ""

    def _parse_snapshot(self, text: str) -> Tuple[Counter, Counter, List[str]]:
        func_counts = Counter()
        pid_counts  = Counter()
        seq: List[str] = []
        for ln in text.splitlines():
            m = FUNC_AT_END.search(ln)
            if m:
                fn = m.group(1)
                seq.append(fn)
                if fn in self.keys:
                    func_counts[fn] += 1
            pm = PID_RE.search(ln)
            if pm:
                pid_counts[int(pm.group(1))] += 1
        return func_counts, pid_counts, seq

    def collect(self) -> Dict[str, float]:
        snap = self._read_trace_snapshot()
        fcounts, pcnts, seq = self._parse_snapshot(snap)

        # graph features from the sequence (cheap approximation)
        gfeats = graph_features_from_sequence(seq, betw_k=32)

        # pick the most active pid (by line hits)
        rss = vms = 0
        cpu = 0.0
        read_count = write_count = 0
        read_bytes = write_bytes = 0
        if pcnts:
            pid, _ = pcnts.most_common(1)[0]
            try:
                p = psutil.Process(pid)
                with p.oneshot():
                    mi = p.memory_info()
                    rss = getattr(mi, "rss", 0) or 0
                    vms = getattr(mi, "vms", 0) or 0
                    cpu = p.cpu_percent(interval=0.0) or 0.0
                    try:
                        io = p.io_counters()
                        read_count  = getattr(io, "read_count", 0)  or 0
                        write_count = getattr(io, "write_count", 0) or 0
                        read_bytes  = getattr(io, "read_bytes", 0)  or 0
                        write_bytes = getattr(io, "write_bytes", 0) or 0
                    except Exception:
                        pass
            except Exception:
                pass

        feat = {k: float(fcounts.get(k, 0)) for k in self.keys}
        # resource counters
        feat["CPU Percent"]     = float(cpu)
        feat["Memory Info RSS"] = float(rss)
        feat["Memory Info VMS"] = float(vms)
        feat["Read Count"]      = float(read_count)
        feat["Write Count"]     = float(write_count)
        feat["Read Bytes"]      = float(read_bytes)
        feat["Write Bytes"]     = float(write_bytes)
        # graph metrics
        feat.update({k: float(v) for k, v in gfeats.items()})
        return feat
