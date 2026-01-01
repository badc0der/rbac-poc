#!/usr/bin/env python3
"""
graph_feats.py
(Kept minimal on dependencies.)

If you already use feature_collector.graph_features_from_sequence(), this module
is optional. We expose a compatible function in case you want to import it
directly elsewhere.

API:
  graph_features_from_fgraph(text, betw_k=32) -> {"betweenness": float, "clustering": float}

It parses a function_graph snapshot text into a flat function sequence and then
computes approximate betweenness & clustering as in feature_collector.
"""
from __future__ import annotations
import re
from collections import defaultdict
from typing import Dict, List, Set

FUNC_AT_END = re.compile(r'([A-Za-z0-9_]+)\(\);?\s*$')

def _sequence_from_fgraph(text: str) -> List[str]:
    seq: List[str] = []
    for ln in text.splitlines():
        m = FUNC_AT_END.search(ln)
        if m:
            seq.append(m.group(1))
    return seq

def graph_features_from_sequence(seq: List[str], betw_k: int = 32) -> Dict[str, float]:
    # identical implementation to the one in feature_collector.py to keep this file stand-alone
    nodes: Set[str] = set(seq)
    if not seq:
        return {"betweenness": 0.0, "clustering": 0.0}
    adj = defaultdict(set)
    radj = defaultdict(set)
    for i in range(len(seq) - 1):
        u, v = seq[i], seq[i+1]
        if u != v:
            adj[u].add(v)
            radj[v].add(u)

    V = list(nodes)
    import random, collections
    sources = V if len(V) <= betw_k else random.sample(V, betw_k)

    def brandes_from_source(s: str):
        S = []
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
        return delta

    Cb = dict((v, 0.0) for v in V)
    for s in sources:
        dep = brandes_from_source(s)
        for v, sc in dep.items():
            if v != s:
                Cb[v] += sc
    if sources:
        for v in V:
            Cb[v] /= float(len(sources))
    betweenness = float(sum(Cb.values()) / max(1, len(V)))

    und = defaultdict(set)
    for u in adj:
        for v in adj[u]:
            und[u].add(v); und[v].add(u)
    tri_sum = 0.0
    valid = 0
    for u in V:
        nu = list(und[u]); k = len(nu)
        if k < 2:
            continue
        valid += 1
        links = 0
        for i in range(k):
            ui = nu[i]
            for j in range(i+1, k):
                uj = nu[j]
                if uj in und[ui]:
                    links += 1
        max_links = k * (k - 1) / 2.0
        tri_sum += (links / max_links) if max_links > 0 else 0.0
    clustering = float(tri_sum / valid) if valid > 0 else 0.0
    return {"betweenness": betweenness, "clustering": clustering}

def graph_features_from_fgraph(text: str, betw_k: int = 32, want_duration: bool = False) -> Dict[str, float]:
    # duration is not reliably available from plain function_graph lines; return only betweenness/clustering
    seq = _sequence_from_fgraph(text)
    feats = graph_features_from_sequence(seq, betw_k=betw_k)
    return feats
