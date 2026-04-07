# linux-basic

Linux 시스템 운영에 필요한 핵심 개념과 실무 적용법을 주제별로 정리한 문서 모음입니다.
단순 명령어 나열이 아닌, 클라우드(AWS) 및 IaC(Terraform, Ansible) 환경과 연계한 실전 예제를 포함합니다.

## 폴더 구조

```
linux-basic/
├── networking/     # 네트워크 설정 및 트러블슈팅
├── storage/        # 스토리지, 파일시스템, 마운트
├── system/         # 부팅, 프로세스, 로그, 스케줄링
└── security/       # 접근 제어, 권한, SSH
```

## 목차

### networking
| 문서 | 주제 |
|---|---|
| [linux-iptables](networking/linux-iptables.md) | 패킷 필터링, NAT, 방화벽 규칙 |
| [linux-hosts-vs-resolv-conf](networking/linux-hosts-vs-resolv-conf.md) | 이름 해석: /etc/hosts vs /etc/resolv.conf |
| [linux-ip-command](networking/linux-ip-command.md) | ip 명령어, 라우팅, 다중 ENI |
| [linux-ss-netstat](networking/linux-ss-netstat.md) | 포트/소켓 상태 조회, 연결 수 집계, 트러블슈팅 |
| [linux-load-balancer](networking/linux-load-balancer.md) | L4/L7 동작원리, 알고리즘, AWS ALB/NLB, 장애 패턴 |
| [linux-dns-internals](networking/linux-dns-internals.md) | DNS 쿼리 흐름, TTL, dig 실전, Route53 Private Zone |
| [linux-network-tuning](networking/linux-network-tuning.md) | TCP 스택 튜닝, 소켓 버퍼, 고성능 네트워크 설정 |
| [linux-nftables](networking/linux-nftables.md) | nftables 개념, iptables 대체, 규칙 작성 |
| [linux-tc](networking/linux-tc.md) | tc(traffic control), 대역폭 제한, QoS, netem |

### storage
| 문서 | 주제 |
|---|---|
| [linux-fstab](storage/linux-fstab.md) | /etc/fstab, 파일시스템 자동 마운트 |
| [linux-lsblk](storage/linux-lsblk.md) | 블록 장치 조회, UUID 확인 |
| [linux-volume-mount](storage/linux-volume-mount.md) | EBS 볼륨 연결 → 포맷 → 마운트 → 확장 전체 흐름 |
| [linux-df-du](storage/linux-df-du.md) | 파일시스템/디렉토리 사용량, 디스크 풀 장애 대응 |
| [linux-package-managers](storage/linux-package-managers.md) | rpm/yum/dnf/apt 비교, 리포지토리 관리 |
| [linux-nfs-efs-mount](storage/linux-nfs-efs-mount.md) | NFS/EFS 마운트, UID/GID 권한 모델, 액세스 포인트 |
| [linux-inode](storage/linux-inode.md) | inode 구조, hardlink/symlink, inode 고갈 장애 |
| [linux-lvm](storage/linux-lvm.md) | LVM PV/VG/LV 개념, 볼륨 생성·확장·스냅샷 |
| [linux-overlayfs](storage/linux-overlayfs.md) | OverlayFS 레이어 구조, Docker/컨테이너 연계 |

### system
| 문서 | 주제 |
|---|---|
| [linux-rc-local-systemd](system/linux-rc-local-systemd.md) | 부팅 시 자동 실행: rc.local vs systemd |
| [linux-journalctl](system/linux-journalctl.md) | systemd 로그 조회 및 장애 대응 |
| [linux-crontab](system/linux-crontab.md) | 주기적 작업 스케줄링 |
| [linux-process-management](system/linux-process-management.md) | 프로세스 조회/종료/우선순위 조정 |
| [linux-directory-structure](system/linux-directory-structure.md) | FHS 디렉토리 구조: /opt, /usr/local/bin 등 |
| [linux-shell-scripting](system/linux-shell-scripting.md) | Bash 스크립트, sed, awk 실전 패턴 |
| [linux-aws-cli](system/linux-aws-cli.md) | AWS CLI 명령어, EC2/S3/SSM 자동화 스크립트 |
| [linux-os-upgrade](system/linux-os-upgrade.md) | 인플레이스 OS 업그레이드, 블루/그린 전략 |
| [linux-environment-variables](system/linux-environment-variables.md) | 환경변수 관리, .bashrc/.profile 차이, systemd 서비스 env |
| [linux-cpu-cores](system/linux-cpu-cores.md) | 물리/논리 코어, 명령어별 스레드 사용, 병렬화, load average |
| [linux-memory](system/linux-memory.md) | 가상메모리, 페이지 캐시, RSS/VSZ, OOM killer, Swap |
| [linux-process-thread](system/linux-process-thread.md) | 프로세스 vs 스레드, fork/exec, namespace/cgroup, 컨테이너 기초 |
| [linux-cgroup](system/linux-cgroup.md) | cgroup v1/v2, cpu/memory/io 제한, systemd, Docker/K8s 연계 |
| [linux-namespace](system/linux-namespace.md) | Linux namespace 종류, pid/net/mnt/user ns, 컨테이너 격리 |
| [linux-hugepages](system/linux-hugepages.md) | HugePage 원리, 설정, NUMA, JVM/DB 연계 |
| [linux-sysctl](system/linux-sysctl.md) | 커널 파라미터 튜닝, net/vm/fs 주요 항목, 영구 적용 |
| [linux-perf](system/linux-perf.md) | perf 명령어, CPU 프로파일링, flame graph |
| [linux-strace](system/linux-strace.md) | strace 시스템콜 추적, 장애 디버깅 실전 |
| [linux-ebpf](system/linux-ebpf.md) | eBPF 동작 원리, bcc/bpftrace 도구, 관측 가능성 |
| [linux-coredump](system/linux-coredump.md) | coredump 생성·분석, gdb 활용, ulimit 설정 |

### security
| 문서 | 주제 |
|---|---|
| [linux-ssh-sshd](security/linux-ssh-sshd.md) | SSH 키 관리, sshd 보안 설정, Bastion |
| [linux-file-permissions](security/linux-file-permissions.md) | chmod, chown, umask, 특수 권한 비트 |
| [linux-audit](security/linux-audit.md) | auditd 시스템 감사, 규칙 설정, aureport/ausearch |
| [linux-seccomp](security/linux-seccomp.md) | seccomp 시스템콜 필터링, Docker/K8s 보안 프로파일 |
