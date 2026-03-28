## 1. 개요

OS 업그레이드는 크게 **인플레이스(In-place)** 방식과 **블루/그린(Blue/Green)** 방식으로 나뉜다.
인플레이스는 기존 서버에서 직접 OS 버전을 올리는 방식으로 빠르지만 위험하고,
블루/그린은 새 OS의 서버를 별도로 구성한 뒤 트래픽을 전환하는 방식으로 안전하지만 리소스가 더 필요하다.
클라우드 환경에서는 블루/그린이 표준이지만, 인플레이스가 불가피한 상황도 있으므로 두 방식 모두 이해해야 한다.

---

## 2. 방식 비교

| | 인플레이스 (In-place) | 블루/그린 (Blue/Green) |
|---|---|---|
| **방법** | 기존 서버에서 버전 업 | 새 서버 구성 후 트래픽 전환 |
| **다운타임** | 수분~수십분 발생 | 거의 없음 (로드밸런서 전환) |
| **롤백** | 어려움 (스냅샷 필요) | 쉬움 (이전 서버로 전환) |
| **위험도** | 높음 | 낮음 |
| **비용** | 추가 비용 없음 | 일시적으로 서버 2배 비용 |
| **적합한 경우** | 단일 서버, 물리 장비 | 클라우드, 오토스케일링 환경 |

---

## 3. Ubuntu 인플레이스 업그레이드 (do-release-upgrade)

### 3.1 사전 준비 (필수)

```bash
# 1. 현재 버전 확인
lsb_release -a
# Ubuntu 22.04.3 LTS (Jammy Jellyfish)
cat /etc/os-release

# 2. 스냅샷/AMI 백업 (실패 시 롤백용)
# AWS 콘솔 또는 CLI로 AMI 생성
aws ec2 create-image \
    --instance-id $(curl -s http://169.254.169.254/latest/meta-data/instance-id) \
    --name "pre-upgrade-$(date '+%Y%m%d')" \
    --no-reboot

# 3. 현재 설치된 패키지 전체 업데이트 (업그레이드 전 필수)
apt update && apt upgrade -y
apt autoremove -y

# 4. 설치된 PPA 및 서드파티 리포지토리 확인 (업그레이드 중 충돌 원인)
apt-cache policy
ls /etc/apt/sources.list.d/

# 5. 디스크 여유 공간 확인 (최소 5GB 이상 권장)
df -h /

# 6. 실행 중인 서비스 목록 저장 (업그레이드 후 비교용)
systemctl list-units --type=service --state=running > /root/services-before.txt

# 7. 중요 설정 파일 백업
cp -r /etc /root/etc-backup-$(date '+%Y%m%d')
```

### 3.2 업그레이드 실행

```bash
# update-manager-core 패키지 확인
apt install update-manager-core

# /etc/update-manager/release-upgrades 설정 확인
cat /etc/update-manager/release-upgrades
# [DEFAULT]
# Prompt=lts   ← lts: LTS → LTS만 업그레이드, normal: 모든 버전

# SSH 세션이 끊기면 중단될 수 있으므로 tmux/screen 안에서 실행
tmux new-session -s upgrade

# 업그레이드 실행
do-release-upgrade

# SSH 원격 접속의 경우 임시 포트(1022) 추가 안내가 뜸
# 보안 그룹에 1022 포트 임시 허용 필요
```

### 3.3 업그레이드 중 주요 프롬프트

```
# 설정 파일 충돌 시 선택
# 패키지 관리자가 수정한 설정 vs 직접 수정한 설정
Configuration file '/etc/ssh/sshd_config'
 ==> Modified (by you or by a script) since installation.
 ==> Package distributor has shipped an updated version.
   What would you like to do about it ?  Your options are:
    Y or I  : install the package maintainer's version   # 패키지 기본값으로 덮어씀
    N or O  : keep your currently-installed version      # 기존 설정 유지 (권장)
    D       : show the differences between the versions  # 차이 확인 후 결정
```

> **원칙**: 직접 수정한 중요 설정 파일(sshd_config, nginx.conf 등)은 `N`으로 기존 유지 선택. 업그레이드 후 필요한 옵션만 수동으로 머지한다.

### 3.4 업그레이드 후 검증

```bash
# 버전 확인
lsb_release -a
uname -r   # 커널 버전

# 서비스 상태 확인
systemctl list-units --type=service --state=failed
diff /root/services-before.txt <(systemctl list-units --type=service --state=running)

# 주요 서비스 개별 확인
systemctl status nginx
systemctl status sshd
systemctl status docker

# 로그에서 에러 확인
journalctl -p err --since "1 hour ago"

# 재부팅 후 재확인 (커널 업데이트 반영)
reboot
```

---

## 4. RHEL/CentOS 인플레이스 업그레이드 (leapp)

### 4.1 CentOS 7 → RHEL/AlmaLinux 8

```bash
# 1. 사전 준비
yum update -y
yum install epel-release -y

# 2. leapp 패키지 설치
yum install leapp leapp-upgrade -y

# 3. 업그레이드 전 사전 검사 (실제 업그레이드는 안 함)
leapp preupgrade

# 결과 확인: /var/log/leapp/leapp-report.txt
cat /var/log/leapp/leapp-report.txt
# Risk Factor: high    ← 반드시 해결해야 함
# Risk Factor: medium  ← 해결 권장
# Risk Factor: low     ← 정보성

# 4. 알려진 문제 해결 (leapp이 안내하는 조치 수행)
# 예: 구형 드라이버 비활성화
leapp answer --section remove_pam_pkcs11_module_check.confirm=True

# 5. 업그레이드 실행 (재부팅 포함)
leapp upgrade
reboot
```

### 4.2 Amazon Linux 2 → Amazon Linux 2023

Amazon Linux 2에서 AL2023으로의 인플레이스 업그레이드는 **공식 지원하지 않는다.**
AWS 권장 방법은 블루/그린 방식이다.

```bash
# 현재 버전 확인
cat /etc/os-release
# Amazon Linux 2 → Amazon Linux 2023은 인플레이스 불가

# 권장: 새 AL2023 인스턴스 생성 + 데이터 마이그레이션
```

---

## 5. 블루/그린 업그레이드 (AWS 권장 방식)

### 5.1 전략

```
현재 (Blue)                      신규 (Green)
┌─────────────────┐              ┌─────────────────┐
│ Ubuntu 20.04    │              │ Ubuntu 22.04    │
│ app v1.0        │              │ app v1.0        │
│ Load Balancer ──┤              └────────┬────────┘
│ Target Group A  │                       │
└─────────────────┘              검증 완료 후 Target Group 전환
                                          │
                                 ALB → Target Group B (Green)
```

### 5.2 Terraform으로 블루/그린 구현

```hcl
variable "active_color" {
  default = "blue"   # "green"으로 변경해서 전환
}

locals {
  ami = {
    blue  = "ami-ubuntu2004-xxxx"   # 현재 운영
    green = "ami-ubuntu2204-xxxx"   # 신규 OS
  }
}

resource "aws_launch_template" "app" {
  name_prefix   = "app-${var.active_color}-"
  image_id      = local.ami[var.active_color]
  instance_type = "t3.medium"
}

resource "aws_autoscaling_group" "app" {
  name = "app-${var.active_color}"
  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }
  target_group_arns = [aws_lb_target_group.app[var.active_color].arn]
}

# active_color = "green"으로 변경 후 terraform apply
# → Green ASG로 트래픽 전환, Blue는 유지 (롤백용)
```

---

## 6. 커널만 업데이트 (보안 패치)

OS 버전 업그레이드와 달리 커널 보안 패치는 더 자주, 더 안전하게 수행한다.

```bash
# ===== Ubuntu =====
# 설치된 커널 목록
dpkg -l | grep linux-image

# 커널 업데이트
apt update && apt upgrade -y linux-image-generic

# 재부팅 없이 일부 커널 패치 적용 (Ubuntu Pro: Livepatch)
# canonical-livepatch enable <token>

# 재부팅 필요 여부 확인
cat /var/run/reboot-required 2>/dev/null && echo "재부팅 필요" || echo "재부팅 불필요"

# 오래된 커널 제거 (현재 사용 중인 커널은 보호됨)
apt autoremove --purge

# ===== RHEL/Amazon Linux =====
# 커널만 업데이트
yum update kernel -y

# 현재 사용 중인 커널
uname -r

# 설치된 커널 목록
rpm -q kernel

# 재부팅 후 이전 커널로 부팅하고 싶을 때 (GRUB에서 선택 가능)
grub2-set-default 1   # 1 = 두 번째 항목(이전 커널)
```

---

## 7. 업그레이드 전 체크리스트

```
사전 준비
□ AMI/스냅샷 백업 완료
□ 중요 설정 파일 별도 백업 (/etc, 앱 설정)
□ 현재 실행 중인 서비스 목록 저장
□ 디스크 여유 공간 5GB 이상 확인
□ 패키지 전체 업데이트 완료 (apt upgrade / yum update)
□ 서드파티 리포지토리/PPA 목록 확인
□ tmux/screen 세션 준비 (SSH 끊김 대비)
□ 임시 포트(1022 등) 보안 그룹 허용

업그레이드 후 검증
□ OS 버전 확인 (lsb_release -a / cat /etc/os-release)
□ 커널 버전 확인 (uname -r)
□ 주요 서비스 상태 확인 (nginx, sshd, app 등)
□ failed 상태 서비스 없음 확인
□ 애플리케이션 기능 테스트
□ 로그 에러 없음 확인 (journalctl -p err)
□ 재부팅 1회 실시 및 자동 시작 확인
```

## 8. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| 백업 없이 업그레이드 시작 | AMI 또는 스냅샷 생성 후 진행 |
| SSH 직접 연결에서 업그레이드 (끊기면 중단) | `tmux`나 `screen` 안에서 실행 |
| 서드파티 PPA 정리 없이 업그레이드 | 업그레이드 전 불필요한 PPA 제거 |
| 설정 파일 충돌 시 무조건 새 버전 선택 | 직접 수정한 파일은 기존 유지 후 수동 머지 |
| 업그레이드 후 재부팅 없이 검증 | 반드시 재부팅 후 최종 확인 |
| AL2 → AL2023 인플레이스 시도 | 공식 미지원, 블루/그린으로 전환 |
