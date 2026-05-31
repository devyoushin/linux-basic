# High Memory Runbook

## 증상

메모리 여유가 줄고 swap 사용량이 증가하거나 OOM killer가 발생합니다.

## 1. 현재 상태 확인

```bash
free -h
vmstat 1 5
grep -E 'MemAvailable|SwapFree|Dirty|Writeback|Slab|SReclaimable' /proc/meminfo
```

## 2. 프로세스 확인

```bash
ps -eo pid,ppid,user,%mem,rss,vsz,comm --sort=-rss | head -20
```

## 3. OOM 이력 확인

```bash
journalctl -k --since "24 hours ago" | grep -Ei 'oom|out of memory|killed process'
```

## 4. 판단

- RSS가 큰 단일 프로세스가 있는지 확인합니다.
- Slab/SReclaimable이 비정상적으로 큰지 확인합니다.
- Dirty/Writeback이 높으면 디스크 writeback 지연을 같이 봅니다.
- swap in/out이 발생하면 응답 지연으로 이어질 수 있습니다.

## 관련 문서

- `docs/system/linux-memory.md`
- `docs/system/linux-memory-pressure.md`
- `docs/system/linux-swap.md`
