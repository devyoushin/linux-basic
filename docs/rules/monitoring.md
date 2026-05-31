# 모니터링 및 확인 기준

Linux 문서의 모니터링/트러블슈팅 섹션 작성 기준입니다.

---

## 1. 기본 상태 확인 명령어

```bash
# 시스템 전체 상태
top                          # CPU/메모리 실시간 모니터링
free -h                      # 메모리 사용량
df -h                        # 디스크 사용량
ss -tlnp                     # 열린 포트 확인
journalctl -xe               # 최근 시스템 로그
```

## 2. 카테고리별 핵심 확인 항목

| 카테고리 | 핵심 명령어 | 확인 포인트 |
|---------|-----------|----------|
| 네트워킹 | `ss -s`, `ip route` | 연결 상태, 라우팅 |
| 스토리지 | `df -h`, `iostat -x` | 용량, I/O 대기 |
| 시스템 | `top`, `vmstat 1` | CPU/메모리 사용률 |
| 보안 | `ausearch -k`, `last` | 감사 로그, 로그인 이력 |

## 3. 로그 확인 패턴

```bash
# systemd 로그 (최근 100줄)
journalctl -n 100 --no-pager

# 특정 서비스 로그
journalctl -u <SERVICE> --since "1 hour ago"

# 커널 메시지
dmesg -T | tail -50

# 실시간 로그 스트리밍
journalctl -f -u <SERVICE>
```

## 4. AWS CloudWatch 연계

Linux 문서에서 AWS 환경 모니터링 언급 시:

```bash
# CloudWatch Agent 상태 확인
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a status
```

주요 CloudWatch 메트릭:
- `mem_used_percent` — 메모리 사용률
- `disk_used_percent` — 디스크 사용률
- `netstat_tcp_established` — TCP 연결 수
