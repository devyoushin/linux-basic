# Linux 커널 모듈 관리

## 1. 개요

커널 모듈(Kernel Module)은 커널 재컴파일 없이 기능을 동적으로 추가/제거할 수 있는 코드 단위다. 네트워크 드라이버, 파일시스템, 하드웨어 지원 등 대부분의 커널 기능이 모듈로 제공된다. 실무에서는 네트워크 드라이버 교체, 커널 파라미터 조정, 커스텀 모듈 배포 시 반드시 이해해야 한다.

---

## 2. 설명

### 2.1 모듈 구조

```
/lib/modules/$(uname -r)/
├── kernel/
│   ├── drivers/       # 하드웨어 드라이버
│   ├── fs/            # 파일시스템 (ext4, xfs, overlay...)
│   ├── net/           # 네트워크 프로토콜/드라이버
│   └── arch/          # 아키텍처별 모듈
├── modules.dep        # 모듈 의존성 맵 (depmod이 생성)
├── modules.alias      # 하드웨어 ID → 모듈명 매핑
└── modules.builtin    # 커널에 정적 내장된 모듈 목록
```

모듈 파일 확장자는 `.ko` (Kernel Object). 커널 5.x부터 압축 포맷(`.ko.xz`, `.ko.zst`)도 지원한다.

### 2.2 모듈 조회

```bash
# 현재 로드된 모듈 목록 (Module / Size / Used by)
lsmod

# 특정 모듈 상세 정보
modinfo nf_conntrack        # 의존성, 파라미터, 서명, 라이선스 확인
modinfo --field filename nf_conntrack  # 파일 경로만 출력

# 특정 모듈이 로드되어 있는지 확인
lsmod | grep -w ixgbe

# 커널 빌트인 모듈 확인 (modinfo로는 안 보임)
grep '^CONFIG_EXT4' /boot/config-$(uname -r)
# builtin이면 =y, 모듈이면 =m
```

### 2.3 모듈 로드/언로드

```bash
# 모듈 로드 (의존성 자동 해결)
modprobe nf_conntrack

# 파라미터와 함께 로드
modprobe nf_conntrack hashsize=131072

# 모듈 언로드 (사용 중이면 실패)
modprobe -r nf_conntrack

# 강제 언로드 — 커널 불안정 위험
# modprobe -rf nf_conntrack   # 절대 프로덕션에서 사용 금지

# insmod: 의존성 해결 없이 직접 로드 (개발/테스트용)
insmod /path/to/mymodule.ko

# rmmod: 직접 언로드
rmmod mymodule
```

> **주의**: `modprobe -rf`(강제 언로드)는 모듈이 사용 중인 데이터 구조를 해제하지 않아 커널 패닉을 유발할 수 있다. 프로덕션에서는 절대 사용하지 않는다.

### 2.4 모듈 파라미터

```bash
# 모듈 파라미터 목록 확인
modinfo -p nf_conntrack
# hashsize:uint  Size of hash table. If not specified then the kernel tries to...
# max_links:uint  Maximum number of packet fragments...

# 로드 시 파라미터 전달
modprobe tcp_bbr

# 런타임에 파라미터 변경 (writeable 파라미터만)
echo 262144 > /sys/module/nf_conntrack/parameters/hashsize

# 현재 파라미터 값 확인
cat /sys/module/nf_conntrack/parameters/hashsize
cat /sys/module/ixgbe/parameters/InterruptThrottleRate
```

### 2.5 부팅 시 자동 로드

```bash
# /etc/modules-load.d/ — 부팅 시 systemd-modules-load가 로드
echo "nf_conntrack" > /etc/modules-load.d/conntrack.conf
echo "br_netfilter" >> /etc/modules-load.d/conntrack.conf

# /etc/modprobe.d/ — 모듈별 옵션/별칭/블랙리스트 설정
cat /etc/modprobe.d/conntrack.conf
# options nf_conntrack hashsize=131072

# 설정 반영 확인 (실제 로드는 재부팅 후)
systemctl restart systemd-modules-load
```

### 2.6 모듈 블랙리스트

```bash
# 특정 모듈 로드 차단 (드라이버 충돌, 보안 이슈)
cat /etc/modprobe.d/blacklist-nouveau.conf
# blacklist nouveau
# options nouveau modeset=0

# 즉시 언로드 + 블랙리스트 적용 (임시)
modprobe -r nouveau
echo "blacklist nouveau" >> /etc/modprobe.d/blacklist.conf

# initramfs 재생성 (부팅 시에도 차단)
dracut --force          # RHEL/CentOS
update-initramfs -u     # Debian/Ubuntu
```

### 2.7 의존성 관리

```bash
# 모듈 의존성 DB 재생성 (새 커널 설치 후 실행)
depmod -a
depmod -a 6.1.0-28-amd64   # 특정 커널 버전 지정

# 모듈 의존성 트리 확인
modprobe --show-depends sch_fq_codel
# insmod /lib/modules/.../sch_fq_codel.ko

# 특정 모듈에 의존하는 모듈 역방향 조회
grep nf_conntrack /lib/modules/$(uname -r)/modules.dep
```

### 2.8 커스텀 모듈 빌드 (DKMS)

DKMS(Dynamic Kernel Module Support)는 커널 업그레이드 시 외부 모듈을 자동으로 재빌드한다. AWS에서 ENA/EFA 드라이버, Nvidia GPU 드라이버 등에 사용된다.

```bash
# DKMS 설치
yum install -y dkms kernel-devel

# 모듈 소스 배포 구조
/usr/src/mymodule-1.0/
├── dkms.conf          # DKMS 메타데이터
├── Makefile
└── mymodule.c

# dkms.conf 예시
cat /usr/src/mymodule-1.0/dkms.conf
# PACKAGE_NAME="mymodule"
# PACKAGE_VERSION="1.0"
# BUILT_MODULE_NAME[0]="mymodule"
# DEST_MODULE_LOCATION[0]="/kernel/drivers/misc"
# AUTOINSTALL="yes"

# DKMS에 모듈 등록 → 빌드 → 설치
dkms add -m mymodule -v 1.0
dkms build -m mymodule -v 1.0
dkms install -m mymodule -v 1.0

# 현재 DKMS 모듈 상태 확인
dkms status
```

### 2.9 모듈 서명 (Secure Boot)

Secure Boot 환경에서는 서명되지 않은 모듈 로드가 차단된다.

```bash
# 서명 키 생성
openssl req -new -x509 -newkey rsa:2048 -keyout signing_key.pem \
  -out signing_cert.pem -days 3650 -subj "/CN=Module Signing/"

# 모듈에 서명
/usr/src/linux-headers-$(uname -r)/scripts/sign-file \
  sha256 signing_key.pem signing_cert.pem mymodule.ko

# 모듈 서명 확인
modinfo mymodule.ko | grep -E 'sig|signer'

# Secure Boot 상태 확인
mokutil --sb-state
```

### 2.10 Terraform/Ansible로 모듈 관리

```yaml
# Ansible: 커널 모듈 로드 및 영구 설정
- name: Load br_netfilter for Kubernetes
  community.general.modprobe:
    name: br_netfilter
    state: present

- name: Persist module load on boot
  ansible.builtin.copy:
    dest: /etc/modules-load.d/k8s.conf
    content: |
      br_netfilter
      overlay

- name: Set module parameters
  ansible.builtin.copy:
    dest: /etc/modprobe.d/conntrack.conf
    content: |
      options nf_conntrack hashsize=131072
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| `insmod`로 의존성 있는 모듈 로드 시도 → `Unknown symbol` 오류 | `modprobe` 사용 — 의존성 자동 해결 |
| 블랙리스트 추가 후 initramfs 미재생성 → 부팅 시 여전히 로드됨 | `dracut --force` 또는 `update-initramfs -u` 실행 |
| 커널 업그레이드 후 외부 모듈 수동 재빌드 | DKMS 사용으로 자동 재빌드 |
| `/sys/module/<name>/parameters/`를 변경해도 재부팅 후 초기화 | `/etc/modprobe.d/`에 `options` 지시어로 영구화 |
| Secure Boot 환경에서 서명 없는 모듈 배포 → `Operation not permitted` | DKMS + 서명 키로 빌드 파이프라인 구성 |
| 모듈 파라미터 변경을 위해 언로드 후 재로드 시 서비스 중단 | 런타임 변경 가능한 파라미터는 `/sys/module/` 경로로 변경 |

---

## 4. 트러블슈팅

### 모듈 로드 실패

```bash
# 오류 메시지 확인
dmesg | tail -20
journalctl -k | grep -i "module\|error" | tail -20

# 의존성 불일치 (커널 버전 mismatch)
modinfo mymodule.ko | grep vermagic
uname -r
# vermagic과 uname -r이 다르면 재빌드 필요

# 심볼 충돌
dmesg | grep "Unknown symbol"
# Unknown symbol nf_conntrack_in (err -22)
# → nf_conntrack 먼저 로드
modprobe nf_conntrack && modprobe mymodule
```

### 모듈이 언로드되지 않음

```bash
# 사용 카운트 확인 (Used by 컬럼)
lsmod | grep nf_conntrack
# nf_conntrack  180224  3  nf_nat,xt_conntrack,nft_ct
# → 3개 모듈이 사용 중 — 먼저 의존 모듈 언로드

modprobe -r nf_nat xt_conntrack nft_ct
modprobe -r nf_conntrack

# 프로세스가 모듈 점유 중인 경우
fuser -v /dev/mydevice
lsof | grep mymodule
```
