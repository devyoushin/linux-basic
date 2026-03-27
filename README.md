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

### storage
| 문서 | 주제 |
|---|---|
| [linux-fstab](storage/linux-fstab.md) | /etc/fstab, 파일시스템 자동 마운트 |
| [linux-lsblk](storage/linux-lsblk.md) | 블록 장치 조회, UUID 확인 |

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

### security
| 문서 | 주제 |
|---|---|
| [linux-ssh-sshd](security/linux-ssh-sshd.md) | SSH 키 관리, sshd 보안 설정, Bastion |
| [linux-file-permissions](security/linux-file-permissions.md) | chmod, chown, umask, 특수 권한 비트 |
