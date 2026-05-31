# High CPU Runbook

## 증상

CPU 사용률이 높고 load average가 평소보다 증가합니다.

## 1. 현재 상태 확인

```bash
uptime
top
ps -eo pid,ppid,user,stat,%cpu,%mem,comm --sort=-%cpu | head -20
```

## 2. 프로세스 세부 확인

```bash
pid=<PID>
ps -fp "$pid"
cat /proc/"$pid"/status
ls -l /proc/"$pid"/fd | head
```

## 3. 시스템 관점 확인

```bash
vmstat 1 5
mpstat -P ALL 1 5
journalctl --since "30 minutes ago" -p warning..alert --no-pager
```

## 4. 판단

- user CPU가 높으면 애플리케이션 루프, 계산 작업, 요청 증가를 봅니다.
- system CPU가 높으면 syscall, network, disk interrupt를 봅니다.
- iowait가 높으면 디스크 지연을 먼저 봅니다.
- load는 높은데 CPU idle이 남아 있으면 D state, I/O wait, lock 대기를 의심합니다.

## 관련 문서

- `docs/system/linux-process-management.md`
- `docs/system/linux-scheduler.md`
- `docs/system/linux-perf.md`
