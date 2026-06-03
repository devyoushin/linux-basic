# linux-basic

Linux 시스템, 네트워킹, 스토리지, 보안, 성능 진단을 운영 관점으로 정리한 개인 지식 베이스입니다.

## 어디서 시작할까

- 문서 지도: `docs/README.md`
- 운영/실습 자산: `ops/README.md`
- AI 작업 지침: `CLAUDE.md`, `AGENTS.md -> CLAUDE.md`

## 구조

| 경로 | 내용 |
|------|------|
| `docs/` | Linux 시스템, 네트워킹, 스토리지, 보안 문서와 작성 규칙 |
| `ops/` | 향후 실습 스크립트와 운영 자동화 자산 |
| `.claude/` | Claude Code 커맨드와 설정 |
| `CLAUDE.md` | Claude/Codex 공통 작업 지침 원본 |
| `AGENTS.md -> CLAUDE.md` | Codex/agent 작업 지침 링크 |

## 학습 흐름

1. `docs/system/`에서 프로세스, 메모리, systemd, cgroup, 커널 기본기 학습
2. `docs/networking/`에서 TCP/IP, conntrack, iptables/nftables, tcpdump 학습
3. `docs/storage/`에서 파일시스템, LVM, NFS/EFS, I/O 진단 학습
4. `docs/security/`에서 계정, SSH, 권한, SELinux, seccomp 학습
