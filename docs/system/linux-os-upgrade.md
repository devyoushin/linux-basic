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

## 8. 보안 솔루션 충돌 트러블슈팅

OS 업그레이드 실패 원인 중 상당수는 보안 솔루션(EDR, 백신, FIM, IPS 에이전트)과의 충돌이다.
보안팀의 협조 없이 단독으로 해결하려다 보안 정책 위반이 될 수 있으므로, 반드시 보안팀과 사전 협의 후 진행한다.

### 8.1 충돌 유형별 원인

| 충돌 유형 | 원인 | 대표 증상 |
|---|---|---|
| **커널 모듈 불일치** | DKMS로 빌드된 보안 에이전트 모듈이 신규 커널 버전을 지원 안 함 | 업그레이드 후 부팅 실패, 커널 패닉 |
| **파일 무결성 모니터링(FIM) 차단** | AIDE, Tripwire 등이 시스템 파일 변경을 실시간 차단 | dpkg/rpm 설치 중 권한 오류, 파일 교체 실패 |
| **패키지 관리자 훅 충돌** | 보안 에이전트가 apt/yum 훅을 점유해 충돌 발생 | 패키지 설치 hang, dpkg lock 오류 |
| **시스템콜/프로세스 모니터링 간섭** | EDR이 업그레이드 프로세스를 악성 행위로 오탐해 kill | 업그레이드 프로세스 갑작스러운 종료 |
| **에이전트 자체 손상** | 업그레이드 중 에이전트 바이너리/라이브러리가 교체되어 동작 불가 | 업그레이드 후 보안 에이전트 서비스 실패 |
| **SELinux/AppArmor 정책 충돌** | 보안 에이전트가 커스터마이즈한 MAC 정책이 신 OS 기본 정책과 충돌 | AVC denied, 서비스 시작 실패 |

### 8.2 충돌 진단

#### 어떤 보안 솔루션이 설치되어 있는지 파악

```bash
# 실행 중인 보안 관련 서비스 확인
systemctl list-units --type=service | grep -Ei \
  'falcon|crowdstrike|sentinelone|cbagent|carbon|trend|ds_agent|ahnlab|v3|symantec|mcafee|trellix|aide|ossec|wazuh'

# 보안 에이전트가 설치한 커널 모듈 확인
lsmod | grep -Ei 'falcon|cs|cbsensor|ds_agent|vshield'

# DKMS로 관리되는 커널 모듈 목록
dkms status

# 설치된 패키지 중 보안 관련 항목 검색 (Ubuntu)
dpkg -l | grep -Ei 'falcon|crowdstrike|sentinelone|trend|mcafee|trellix|aide|ossec'

# 설치된 패키지 중 보안 관련 항목 검색 (RHEL 계열)
rpm -qa | grep -Ei 'falcon|crowdstrike|sentinelone|trend|mcafee|trellix|aide|ossec'
```

#### 업그레이드 로그에서 차단 흔적 찾기

```bash
# Ubuntu do-release-upgrade 로그
cat /var/log/dist-upgrade/main.log
grep -i 'error\|fail\|kill\|denied' /var/log/dist-upgrade/main.log

# dpkg 설치 실패 로그
cat /var/log/dpkg.log | grep -i 'error\|half-installed'

# RHEL leapp 사전 검사 리포트
cat /var/log/leapp/leapp-report.txt | grep -A5 'Risk Factor: high'

# SELinux 차단 로그
ausearch -m avc --start today | grep denied
dmesg | grep -i 'avc: denied'

# 시스템 전체 에러 로그 (업그레이드 시점 기준)
journalctl -p err --since "2 hours ago"
```

#### DKMS 모듈과 커널 버전 불일치 확인

```bash
# 현재 커널과 DKMS 모듈 빌드 상태 비교
dkms status
# 출력 예시:
# falconctl/6.44.0, 5.15.0-91-generic, x86_64: installed   ← 정상
# falconctl/6.44.0, 6.5.0-35-generic, x86_64: added        ← 미빌드 = 문제

# 신규 커널용 모듈 강제 재빌드 시도
KERN_VER=$(uname -r)
dkms autoinstall -k "$KERN_VER"
dkms status
```

### 8.3 보안 솔루션별 대응 방법

#### CrowdStrike Falcon

```bash
# Falcon 센서 버전 확인 (신 OS 지원 여부 공식 문서 대조)
/opt/CrowdStrike/falconctl -g --version

# 업그레이드 전: 보안팀에 임시 비활성화 요청 또는
# Falcon 센서를 신 OS 지원 버전으로 선업그레이드

# 업그레이드 후 Falcon 서비스 상태 확인
systemctl status falcon-sensor

# 커널 모듈 재로드 필요 시
rmmod falcon_lsm_serviceable
modprobe falcon_lsm_serviceable
```

#### SentinelOne

```bash
# 에이전트 상태 확인
/opt/sentinelone/bin/sentinelctl status

# 업그레이드 전 passphrase로 에이전트 보호 해제 (보안팀 passphrase 필요)
/opt/sentinelone/bin/sentinelctl unprotect --passphrase "PASSPHRASE"

# 패키지 제거 후 OS 업그레이드, 완료 후 재설치
apt remove sentinelone    # Ubuntu
rpm -e SentinelAgent      # RHEL

# OS 업그레이드 완료 후 신 OS용 에이전트 패키지 재설치
```

#### Trend Micro Deep Security Agent

```bash
# ds_agent 서비스 확인
systemctl status ds_agent

# 업그레이드 전 에이전트 임시 중지 (보안팀 승인 필요)
systemctl stop ds_agent

# 업그레이드 후 에이전트 재시작 및 버전 확인
systemctl start ds_agent
/opt/ds_agent/dsa_query -c GetAgentStatus
```

#### AhnLab V3 (국내 환경)

```bash
# V3 서비스 확인
systemctl status v3medic   # 또는 alyac, v3net 등 에이전트명 확인

# 설치 경로 확인
find /opt /usr/local -name "v3*" -o -name "alyac*" 2>/dev/null

# 업그레이드 전 라이선스/버전 정보 저장
cat /opt/v3medic/version   # 경로는 설치 환경에 따라 다름

# 업그레이드 후 에이전트 재설치 또는 업데이트
# → 보안 담당자에게 신 OS용 패키지 요청
```

#### AIDE / Tripwire (파일 무결성 모니터링)

```bash
# AIDE 실행 여부 확인
systemctl status aide
crontab -l | grep aide
cat /etc/cron.d/aide 2>/dev/null

# 업그레이드 전 AIDE 일시 중지
systemctl stop aide
systemctl disable aide   # 업그레이드 기간 동안만

# Tripwire
systemctl stop tripwire-twprint

# 업그레이드 완료 후 DB 재초기화 (시스템 파일이 정상적으로 바뀌었으므로)
aide --init
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
systemctl enable aide && systemctl start aide
```

### 8.4 leapp preupgrade 결과에서 보안 솔루션 관련 항목 처리 (RHEL 계열)

```bash
# leapp 사전 검사 실행
leapp preupgrade

# 리포트에서 high risk 항목만 필터링
grep -A 10 'Risk Factor: high' /var/log/leapp/leapp-report.txt

# 보안 솔루션 관련 항목 예시:
# Title: Third-party kernel module detected
#   → falconlsm, cbsensor 등 서드파티 커널 모듈이 업그레이드 차단 요인으로 분류됨
#   → 조치: 해당 모듈 언로드 또는 에이전트 제거 후 업그레이드

# 특정 커널 모듈 업그레이드 차단 해제 (leapp inhibitor 확인 후)
leapp answer --section <섹션명>.confirm=True   # leapp이 안내하는 항목 이름 사용

# 커널 모듈 언로드 후 leapp inhibitor 재확인
rmmod falconlsm
leapp preupgrade   # 재실행해서 항목 해소 확인
```

### 8.5 업그레이드 순서 전략

보안 솔루션 충돌을 최소화하는 권장 순서:

```
1. 보안팀 사전 협의
   └─ 업그레이드 일정, 보안 에이전트 임시 비활성화/제거 승인

2. 업그레이드 전 준비
   ├─ AMI/스냅샷 백업
   ├─ 보안 에이전트 버전 및 신 OS 지원 여부 확인
   ├─ DKMS 모듈 상태 확인 (dkms status)
   └─ FIM(AIDE/Tripwire) 비활성화

3. 보안 에이전트 처리 방식 선택
   ├─ [방법 A] 에이전트 임시 중지 → OS 업그레이드 → 에이전트 재시작
   ├─ [방법 B] 에이전트 제거 → OS 업그레이드 → 신 OS용 에이전트 재설치  ← 권장
   └─ [방법 C] 블루/그린으로 전환해 보안 에이전트를 신 OS 이미지에 사전 포함

4. OS 업그레이드 실행

5. 업그레이드 후 복구
   ├─ 보안 에이전트 재설치/시작
   ├─ 에이전트 정상 동작 확인
   ├─ FIM DB 재초기화
   └─ 보안팀에 복구 완료 보고
```

### 8.6 블루/그린에서 보안 에이전트 사전 포함 (AWS)

신규 AMI를 굽는 단계에서 보안 에이전트를 포함시키면 업그레이드 후 에이전트 누락 문제를 방지한다.

```hcl
# Packer로 신 OS AMI 빌드 시 보안 에이전트 포함 예시
resource "null_resource" "bake_ami" {
  provisioner "local-exec" {
    command = <<-EOT
      packer build \
        -var 'base_ami=${var.ubuntu2204_ami}' \
        -var 'falcon_sensor_url=${var.falcon_sensor_url}' \
        packer-ubuntu2204.pkr.hcl
    EOT
  }
}
```

```bash
# packer 스크립트 내 보안 에이전트 설치 예시 (CrowdStrike)
# packer-ubuntu2204.pkr.hcl 의 provisioner shell 섹션
#!/bin/bash
# Falcon 센서 설치 (신 OS 지원 버전)
curl -Lo /tmp/falcon-sensor.deb "${FALCON_SENSOR_URL}"
dpkg -i /tmp/falcon-sensor.deb
/opt/CrowdStrike/falconctl -s --cid="${FALCON_CID}"
systemctl enable falcon-sensor
# 초기 등록 후 CID 연결 확인
/opt/CrowdStrike/falconctl -g --cid
```

---

## 9. 업그레이드 전 체크리스트

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
□ 설치된 보안 솔루션 목록 및 버전 확인 (dkms status, systemctl)
□ 보안팀과 업그레이드 일정 및 에이전트 처리 방법 사전 협의

업그레이드 후 검증
□ OS 버전 확인 (lsb_release -a / cat /etc/os-release)
□ 커널 버전 확인 (uname -r)
□ 주요 서비스 상태 확인 (nginx, sshd, app 등)
□ failed 상태 서비스 없음 확인
□ 보안 에이전트 정상 동작 확인
□ DKMS 모듈 빌드 상태 확인 (dkms status)
□ FIM DB 재초기화 완료
□ 애플리케이션 기능 테스트
□ 로그 에러 없음 확인 (journalctl -p err)
□ 재부팅 1회 실시 및 자동 시작 확인
```

## 10. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| 백업 없이 업그레이드 시작 | AMI 또는 스냅샷 생성 후 진행 |
| SSH 직접 연결에서 업그레이드 (끊기면 중단) | `tmux`나 `screen` 안에서 실행 |
| 서드파티 PPA 정리 없이 업그레이드 | 업그레이드 전 불필요한 PPA 제거 |
| 설정 파일 충돌 시 무조건 새 버전 선택 | 직접 수정한 파일은 기존 유지 후 수동 머지 |
| 업그레이드 후 재부팅 없이 검증 | 반드시 재부팅 후 최종 확인 |
| AL2 → AL2023 인플레이스 시도 | 공식 미지원, 블루/그린으로 전환 |
| 보안팀 협의 없이 에이전트 강제 제거 | 보안팀 사전 승인 후 절차대로 처리 |
| 업그레이드 후 FIM DB 재초기화 누락 | AIDE/Tripwire DB 재초기화 필수 (false alarm 방지) |
| 신 OS 미지원 에이전트 버전 그대로 사용 | 에이전트 벤더 공식 OS 지원 매트릭스 사전 확인 |
