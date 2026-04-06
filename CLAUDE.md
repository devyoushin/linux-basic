# CLAUDE.md - linux-basic 저장소 가이드

이 저장소는 Linux 기초 및 실무 운영에 필요한 내용을 주제별로 정리한 문서 모음입니다.

## 저장소 목적

- Linux 시스템 운영에 필요한 핵심 개념을 **한국어**로 정리
- 단순 명령어 나열이 아닌, **왜** 쓰는지와 **실무 적용법**을 함께 설명
- 클라우드(AWS) 및 IaC(Terraform, Ansible) 환경과 연계한 실전 예제 포함

## 폴더 구조

```
linux-basic/
├── networking/     # 네트워크 설정 및 트러블슈팅
├── storage/        # 스토리지, 파일시스템, 마운트
├── system/         # 부팅, 프로세스, 로그, 스케줄링
└── security/       # 접근 제어, 권한, SSH
```

## 문서 작성 규칙

### 필수 포함 항목
1. **개요 (## 1. 개요)**: 이 도구/파일이 무엇이고 왜 중요한지 2~4줄
2. **설명 (## 2. 설명)**: 개념 설명 + 실무 명령어 + IaC 예제
3. **자주 하는 실수 (## 3. 자주 하는 실수)**: 표 형식으로 실수 → 올바른 방법

### 코드 블록 규칙
- 모든 명령어에 `#` 주석으로 한국어 설명 추가
- Terraform/Ansible 예제는 실제 동작 가능한 수준으로 작성
- 위험한 명령어(삭제, 강제 종료 등)에는 `> **주의**` 경고 추가

### 언어 및 톤
- 본문은 한국어, 기술 용어(명령어, 파일명, 옵션)는 영어 그대로 사용
- 경어체보다는 간결한 서술체 (`~다.`, `~한다.`)
- 클라우드/DevOps 환경을 전제로 설명

### 파일 네이밍
- `linux-{주제}.md` 형식 (예: `linux-iptables.md`)
- 비교/대조 주제는 `linux-{A}-vs-{B}.md` 형식

## 현재 문서 목록

### networking/
| 파일 | 주제 |
|---|---|
| `linux-iptables.md` | 패킷 필터링, NAT, 방화벽 규칙 |
| `linux-hosts-vs-resolv-conf.md` | 이름 해석: /etc/hosts vs /etc/resolv.conf |
| `linux-ip-command.md` | ip 명령어 (ifconfig 대체), 라우팅, ENI |
| `linux-ss-netstat.md` | 포트/소켓 상태 조회, TCP 연결 상태 |
| `linux-load-balancer.md` | L4/L7 동작원리, 알고리즘, ALB/NLB, 장애 패턴 |
| `linux-dns-internals.md` | DNS 쿼리 흐름, TTL, dig 실전, Route53 |

### storage/
| 파일 | 주제 |
|---|---|
| `linux-fstab.md` | /etc/fstab, 파일시스템 자동 마운트 |
| `linux-lsblk.md` | 블록 장치 조회, UUID 확인 |
| `linux-volume-mount.md` | EBS 볼륨 연결 → 포맷 → 마운트 → 확장 |
| `linux-df-du.md` | 디스크 사용량, 디스크 풀 장애 대응 |
| `linux-package-managers.md` | rpm/yum/dnf vs apt/dpkg 비교 |
| `linux-nfs-efs-mount.md` | NFS/EFS 마운트, UID/GID 권한 모델, 액세스 포인트 |

### system/
| 파일 | 주제 |
|---|---|
| `linux-rc-local-systemd.md` | 부팅 시 자동 실행: rc.local vs systemd |
| `linux-journalctl.md` | systemd 로그 조회, 장애 대응 |
| `linux-crontab.md` | 주기적 작업 스케줄링 |
| `linux-process-management.md` | 프로세스 조회/종료/우선순위 |
| `linux-directory-structure.md` | FHS 디렉토리 구조, /opt vs /usr/local 비교 |
| `linux-shell-scripting.md` | Bash 기초, sed, awk, 실전 스크립트 패턴 |
| `linux-aws-cli.md` | AWS CLI, EC2/S3/SSM/CloudWatch 자동화 |
| `linux-os-upgrade.md` | 인플레이스 업그레이드, 블루/그린 전략 |
| `linux-environment-variables.md` | 환경변수, .bashrc/.profile 차이, systemd env |
| `linux-cpu-cores.md` | 물리/논리 코어, 명령어 스레드 특성, 병렬화 |
| `linux-memory.md` | 가상메모리, 페이지 캐시, OOM killer, Swap |
| `linux-process-thread.md` | 프로세스 vs 스레드, fork/exec, namespace/cgroup |

### security/
| 파일 | 주제 |
|---|---|
| `linux-ssh-sshd.md` | SSH 키 관리, sshd 보안 설정, Bastion |
| `linux-file-permissions.md` | chmod, chown, umask, 특수 권한 비트 |

## 추가 예정 주제 (아이디어)

- `networking/linux-tcpdump.md` - 패킷 캡처 및 분석
- `storage/linux-lvm.md` - 논리 볼륨 관리자
- `system/linux-systemctl.md` - systemd 서비스 관리 심화
- `system/linux-logrotate.md` - 로그 파일 순환 관리
- `security/linux-sudo.md` - sudo 설정 및 /etc/sudoers
- `security/linux-ufw-firewalld.md` - 방화벽 프론트엔드 도구
