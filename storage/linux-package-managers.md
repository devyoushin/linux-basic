## 1. 개요

리눅스 패키지 관리자는 소프트웨어의 설치·업데이트·제거·의존성 해결을 자동화한다.
배포판 계열에 따라 도구가 다르며, 저수준(rpm/dpkg)과 고수준(yum/dnf/apt) 두 계층으로 나뉜다.
클라우드 환경에서는 AMI 계열(Amazon Linux, CentOS, Ubuntu)에 따라 쓰는 명령어가 달라지므로 두 계열 모두 익혀두는 것이 필수다.

## 2. 패키지 관리자 계층 구조

```
                    ┌─────────────┐    ┌─────────────┐
    고수준           │  yum / dnf  │    │     apt     │
  (의존성 자동 해결) │(RHEL 계열)  │    │(Debian 계열)│
                    └──────┬──────┘    └──────┬──────┘
                           │                  │
    저수준                  ▼                  ▼
  (단일 패키지 파일 조작)  rpm               dpkg
                    (Red Hat Package)  (Debian Package)
```

| 도구 | 계열 | 패키지 형식 | 주요 배포판 |
|---|---|---|---|
| `rpm` | RHEL | `.rpm` | RHEL, CentOS, Amazon Linux, Fedora |
| `yum` | RHEL | `.rpm` | CentOS 7, Amazon Linux 2 |
| `dnf` | RHEL | `.rpm` | RHEL 8+, CentOS 8+, Amazon Linux 2023, Fedora |
| `dpkg` | Debian | `.deb` | Ubuntu, Debian |
| `apt` | Debian | `.deb` | Ubuntu, Debian |

> `dnf`는 `yum`의 후계자다. Amazon Linux 2023부터 `yum` 명령어는 `dnf`의 별칭(alias)으로 동작한다.

---

## 3. yum / dnf (RHEL 계열)

### 3.1 기본 명령어

```bash
# ===== 패키지 설치 =====
yum install nginx              # 설치 (확인 프롬프트 있음)
yum install -y nginx           # -y: 모든 질문에 yes 자동 응답
dnf install -y nginx           # dnf도 동일한 옵션 구조

# 특정 버전 설치
yum install nginx-1.20.1
dnf install nginx-1.20.1-1.el8

# ===== 업데이트 =====
yum update                     # 전체 패키지 업데이트
yum update nginx               # 특정 패키지만 업데이트
yum update --security          # 보안 패치만 적용

# ===== 제거 =====
yum remove nginx               # 패키지 제거 (의존 패키지는 유지)
yum autoremove                 # 더 이상 필요 없는 의존 패키지 자동 제거

# ===== 검색 및 조회 =====
yum search nginx               # 패키지 이름/설명 검색
yum info nginx                 # 패키지 상세 정보
yum list installed             # 설치된 패키지 전체 목록
yum list installed | grep nginx
yum provides /usr/bin/curl     # 특정 파일을 제공하는 패키지 찾기
```

### 3.2 그룹 패키지

```bash
# 그룹 목록 (Development Tools 등)
yum group list
dnf group list

# 그룹 설치 (관련 패키지 묶음 한 번에 설치)
yum group install "Development Tools"
dnf group install "Development Tools"
```

### 3.3 리포지토리 관리

```bash
# 활성화된 리포지토리 목록
yum repolist
dnf repolist all   # 비활성화 포함 전체

# 리포지토리 추가 (EPEL: Extra Packages for Enterprise Linux)
yum install epel-release       # Amazon Linux 2 / CentOS 7
dnf install epel-release       # RHEL 8+ / Amazon Linux 2023

# 특정 리포지토리에서만 설치
yum install --enablerepo=epel nginx

# 리포지토리 파일 직접 추가
cat > /etc/yum.repos.d/nginx.repo <<'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
EOF
```

### 3.4 dnf 전용 기능

```bash
# 트랜잭션 이력 확인 및 롤백
dnf history list
dnf history info 5             # 5번 트랜잭션 상세
dnf history undo 5             # 5번 트랜잭션 롤백 (설치 취소 등)

# 패키지 버전 잠금 (업데이트 방지)
dnf install python3-dnf-plugin-versionlock
dnf versionlock add nginx      # nginx 버전 고정
dnf versionlock list           # 고정된 패키지 목록
dnf versionlock delete nginx   # 잠금 해제
```

---

## 4. apt (Debian/Ubuntu 계열)

### 4.1 기본 명령어

```bash
# ===== 패키지 목록 갱신 (설치 전 항상 실행) =====
apt update                     # 리포지토리 인덱스 갱신 (실제 업그레이드 아님)

# ===== 패키지 설치 =====
apt install nginx
apt install -y nginx           # 자동 yes

# 특정 버전 설치
apt install nginx=1.18.0-0ubuntu1

# ===== 업데이트 =====
apt upgrade                    # 설치된 패키지 업그레이드
apt full-upgrade               # 의존성 변경 포함 전체 업그레이드 (구 dist-upgrade)
apt upgrade --only-upgrade nginx  # 특정 패키지만

# ===== 제거 =====
apt remove nginx               # 패키지 제거 (설정 파일 유지)
apt purge nginx                # 설정 파일까지 완전 제거
apt autoremove                 # 불필요해진 의존 패키지 제거
apt autoremove --purge         # 설정 파일까지 포함해서 제거

# ===== 검색 및 조회 =====
apt search nginx
apt show nginx                 # 패키지 상세 정보
apt list --installed           # 설치된 패키지 목록
dpkg -l | grep nginx           # dpkg로 설치 상태 확인
apt-cache policy nginx         # 버전 및 리포지토리 우선순위 확인
```

### 4.2 리포지토리 관리

```bash
# 리포지토리 목록
cat /etc/apt/sources.list
ls /etc/apt/sources.list.d/

# PPA(Personal Package Archive) 추가 (Ubuntu)
add-apt-repository ppa:certbot/certbot
apt update

# 서드파티 리포지토리 추가 (nginx 공식 예시)
curl -fsSL https://nginx.org/keys/nginx_signing.key \
    | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
    http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
    > /etc/apt/sources.list.d/nginx.list

apt update && apt install nginx
```

### 4.3 패키지 버전 고정 (hold)

```bash
# 특정 패키지 버전 고정 (apt upgrade 시 제외)
apt-mark hold nginx
apt-mark showhold              # 고정된 패키지 목록
apt-mark unhold nginx          # 고정 해제
```

---

## 5. rpm / dpkg - 저수준 도구

고수준 도구(yum/apt)로 해결 안 될 때, 또는 `.rpm`/`.deb` 파일을 직접 다룰 때 사용한다.

```bash
# ===== rpm =====
rpm -ivh package.rpm           # 설치 (i:install, v:verbose, h:hash progress)
rpm -Uvh package.rpm           # 업그레이드 (없으면 설치)
rpm -e package-name            # 제거
rpm -qa                        # 설치된 전체 패키지 목록
rpm -qi nginx                  # 패키지 상세 정보
rpm -ql nginx                  # 패키지가 설치한 파일 목록
rpm -qf /usr/sbin/nginx        # 특정 파일이 어느 패키지에서 온 것인지 확인
rpm -V nginx                   # 패키지 파일 무결성 검증

# ===== dpkg =====
dpkg -i package.deb            # 설치
dpkg -r package-name           # 제거 (설정 파일 유지)
dpkg -P package-name           # 완전 제거 (purge)
dpkg -l                        # 설치된 전체 패키지 목록
dpkg -L nginx                  # 패키지가 설치한 파일 목록
dpkg -S /usr/sbin/nginx        # 특정 파일의 패키지 확인
```

---

## 6. 계열별 주요 명령어 비교표

| 작업 | yum/dnf (RHEL) | apt (Ubuntu/Debian) |
|---|---|---|
| 리포지토리 갱신 | (자동) | `apt update` |
| 패키지 설치 | `yum install pkg` | `apt install pkg` |
| 패키지 제거 | `yum remove pkg` | `apt remove pkg` |
| 설정까지 제거 | — | `apt purge pkg` |
| 전체 업데이트 | `yum update` | `apt upgrade` |
| 패키지 검색 | `yum search keyword` | `apt search keyword` |
| 설치 목록 | `yum list installed` | `apt list --installed` |
| 파일 → 패키지 | `yum provides /path` | `dpkg -S /path` |
| 패키지 → 파일 목록 | `rpm -ql pkg` | `dpkg -L pkg` |
| 의존성 정리 | `yum autoremove` | `apt autoremove` |
| 버전 고정 | `dnf versionlock add` | `apt-mark hold` |

---

## 7. Ansible로 패키지 설치 IaC화

```yaml
- name: Install packages (distro-agnostic)
  hosts: all
  tasks:
    # 배포판 자동 감지해서 적절한 패키지 매니저 사용
    - name: Install nginx
      ansible.builtin.package:
        name: nginx
        state: present

    # Ubuntu 전용: apt update 후 설치
    - name: Update apt cache and install
      ansible.builtin.apt:
        name: nginx
        state: present
        update_cache: yes
        cache_valid_time: 3600   # 1시간 이내 캐시는 갱신 생략
      when: ansible_os_family == "Debian"

    # RHEL 전용: dnf 설치
    - name: Install via dnf
      ansible.builtin.dnf:
        name: nginx
        state: present
      when: ansible_os_family == "RedHat"

    # 버전 고정
    - name: Hold nginx version (Ubuntu)
      ansible.builtin.dpkg_selections:
        name: nginx
        selection: hold
      when: ansible_os_family == "Debian"
```

## 8. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| Ubuntu에서 `apt install` 전 `apt update` 생략 | 항상 `apt update && apt install` 순서로 |
| `.rpm` 파일을 `apt`로, `.deb`를 `yum`으로 설치 시도 | 계열에 맞는 저수준 도구(`rpm -ivh` / `dpkg -i`) 사용 |
| `yum remove` 후 의존 패키지 방치 | `yum autoremove` 또는 `apt autoremove` 후속 실행 |
| 버전 고정 없이 자동 업데이트로 서비스 장애 | 중요 패키지는 `versionlock` / `apt-mark hold` 적용 |
| EPEL 없이 RHEL에서 패키지 못 찾음 | `dnf install epel-release` 후 재시도 |
