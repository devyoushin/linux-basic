# linux-selinux.md — SELinux 강제 접근 제어

## 1. 개요

SELinux(Security-Enhanced Linux)는 NSA가 개발한 MAC(Mandatory Access Control) 보안 모듈로, RHEL/CentOS/Amazon Linux 2/Rocky Linux의 기본 보안 메커니즘이다. 일반 DAC(파일 권한)와 달리 프로세스, 파일, 포트, 소켓에 **레이블(context)**을 부여하고 정책(policy)으로 접근을 제어한다. root 계정이 탈취되어도 SELinux 정책이 올바르게 설정되어 있으면 피해 범위를 제한할 수 있다. DevOps/SRE 관점에서는 "SELinux 때문에 작동 안 한다"는 오류를 disable로 해결하는 대신, 올바른 레이블과 boolean 설정으로 해결해야 한다.

---

## 2. 설명

### 2.1 SELinux 상태 확인

```bash
# 현재 모드 확인
getenforce
# Enforcing  — 정책 위반 시 차단 + 로그
# Permissive — 정책 위반 시 차단하지 않고 로그만
# Disabled   — SELinux 비활성화

# 상세 상태 (정책 유형, 설정 파일 경로 등)
sestatus

# 설정 파일 확인
cat /etc/selinux/config
```

### 2.2 모드 전환

```bash
# 즉시 전환 (재부팅 불필요, 재부팅 후 설정 파일 기준으로 복구됨)
setenforce 1    # Enforcing
setenforce 0    # Permissive (디버깅용 임시 전환)

# 영구 설정 (/etc/selinux/config)
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config

# Disabled → Enforcing 전환 시 반드시 파일 재레이블링 후 재부팅
touch /.autorelabel   # 재부팅 시 전체 파일시스템 레이블 재설정
reboot
```

> **주의**: 프로덕션에서 SELinux를 `disabled`로 설정하는 것은 보안 정책 위반이다. 문제 해결은 항상 `permissive`로 임시 전환 후 원인 파악 → 레이블/boolean 수정 → `enforcing` 복귀 순서로 진행한다.

### 2.3 SELinux 컨텍스트(레이블)

```bash
# 파일 컨텍스트 확인 (-Z)
ls -Z /var/www/html/
ls -Z /etc/nginx/

# 프로세스 컨텍스트 확인
ps auxZ | grep nginx
ps -eZ | grep httpd

# 포트 컨텍스트 확인
semanage port -l | grep http

# 네트워크 소켓 컨텍스트
ss -tulZn | grep 443
```

**컨텍스트 형식:** `user:role:type:level`
- 핵심은 **type** (예: `httpd_t`, `var_t`, `etc_t`)
- 정책은 `httpd_t` 프로세스가 어떤 type의 파일/포트에 접근 가능한지 정의

### 2.4 SELinux 거부 로그 분석

```bash
# SELinux 거부 이벤트 확인 (audit.log)
ausearch -m avc -ts recent
ausearch -m avc -ts today

# journald에서 확인
journalctl _AUDIT_TYPE=1400      # AVC 메시지
journalctl | grep "SELinux is preventing"

# audit2why: 거부 이유 설명
ausearch -m avc -ts recent | audit2why

# 거부 로그 예시 읽는 법
# type=AVC msg=audit(1234567890.123:456): avc: denied { read } for pid=1234
# comm="nginx"  path="/data/app/config.conf"
# scontext=system_u:system_r:httpd_t:s0
# tcontext=unconfined_u:object_r:var_t:s0 tclass=file
# └ nginx(httpd_t)가 /data/app/config.conf(var_t) 읽기 거부
```

### 2.5 파일 레이블 수정

```bash
# 파일에 올바른 SELinux 타입 지정
chcon -t httpd_sys_content_t /data/mywebsite/

# 재귀 적용
chcon -R -t httpd_sys_content_t /data/mywebsite/

# 심볼릭 링크 대상도 변경
chcon -h -t httpd_sys_content_t /data/link

# 기본 레이블 정책대로 복원 (chcon 변경사항 되돌리기)
restorecon -v /data/mywebsite/index.html
restorecon -Rv /data/mywebsite/       # 재귀

# 현재 정책의 기본 컨텍스트 확인
matchpathcon /data/mywebsite/index.html
```

### 2.6 파일 레이블 정책 영구 등록 (semanage)

`chcon`은 임시 변경이다. `restorecon` 실행 시 원래대로 돌아간다. 영구적으로 특정 경로에 레이블을 적용하려면 `semanage fcontext`를 사용한다.

```bash
# /data/mywebsite 하위 모든 파일에 httpd_sys_content_t 영구 등록
semanage fcontext -a -t httpd_sys_content_t "/data/mywebsite(/.*)?"

# 정책 등록 후 실제 파일에 적용
restorecon -Rv /data/mywebsite/

# 등록된 정책 확인
semanage fcontext -l | grep mywebsite

# 정책 삭제
semanage fcontext -d "/data/mywebsite(/.*)?"
```

### 2.7 포트 레이블 수정 (비표준 포트 허용)

```bash
# nginx가 8080 포트를 리슨하려면 http_port_t에 추가
semanage port -l | grep http

# 포트 추가
semanage port -a -t http_port_t -p tcp 8080
semanage port -a -t http_port_t -p tcp 9090

# 확인
semanage port -l | grep 8080

# 포트 삭제
semanage port -d -t http_port_t -p tcp 8080
```

### 2.8 SELinux Boolean 설정

Boolean은 정책을 재컴파일하지 않고 특정 동작을 켜고 끄는 스위치다.

```bash
# 현재 boolean 목록
getsebool -a
semanage boolean -l

# 특정 boolean 확인
getsebool httpd_can_network_connect
getsebool httpd_can_network_connect_db

# boolean 활성화 (임시 — 재부팅 후 초기화)
setsebool httpd_can_network_connect on

# 영구 활성화 (-P)
setsebool -P httpd_can_network_connect on
setsebool -P httpd_can_network_connect_db on    # DB 연결 허용
setsebool -P httpd_execmem on                   # JIT 컴파일 허용

# 자주 쓰는 boolean
# httpd_can_network_connect     — nginx/Apache가 외부 네트워크 연결
# httpd_can_network_connect_db  — 웹서버가 DB 직접 연결
# httpd_use_nfs                 — NFS 파일 접근
# container_manage_cgroup       — 컨테이너 cgroup 관리
# virt_sandbox_use_all_caps     — 컨테이너 확장 권한
```

### 2.9 커스텀 정책 모듈 생성 (audit2allow)

거부 로그를 기반으로 최소 권한 정책 모듈을 자동 생성할 수 있다.

```bash
# 1) Permissive 모드에서 동작 후 거부 로그 수집
setenforce 0
# ... 애플리케이션 실행 ...
setenforce 1

# 2) 거부 로그를 정책으로 변환
ausearch -m avc -ts today | audit2allow -M myapp_policy

# 3) 생성된 정책 확인
cat myapp_policy.te

# 4) 정책 모듈 설치
semodule -i myapp_policy.pp

# 5) 설치된 모듈 확인
semodule -l | grep myapp

# 6) 모듈 제거
semodule -r myapp_policy
```

> **주의**: `audit2allow`는 거부된 모든 동작을 허용하는 정책을 생성한다. 불필요한 권한이 포함될 수 있으므로 `.te` 파일을 검토한 후 사용한다.

### 2.10 컨테이너/Kubernetes와 SELinux

```bash
# Docker: SELinux 레이블로 볼륨 마운트
docker run -v /host/data:/data:z myimage   # :z = 공유 레이블 재설정
docker run -v /host/data:/data:Z myimage   # :Z = 전용 레이블 재설정

# containerd / Kubernetes: RuntimeClass로 SELinux 설정
# /etc/kubernetes/manifests/ 또는 Pod spec
```

```yaml
# Kubernetes Pod spec에서 SELinux 설정
spec:
  securityContext:
    seLinuxOptions:
      level: "s0:c123,c456"
  containers:
  - name: myapp
    securityContext:
      seLinuxOptions:
        type: container_t
```

### 2.11 Ansible로 SELinux 관리

```yaml
- name: Set SELinux to enforcing
  selinux:
    policy: targeted
    state: enforcing

- name: Allow nginx to use port 8080
  seport:
    ports: 8080
    proto: tcp
    setype: http_port_t
    state: present

- name: Set file context for web content
  sefcontext:
    target: '/data/mywebsite(/.*)?'
    setype: httpd_sys_content_t
    state: present

- name: Apply file context
  command: restorecon -Rv /data/mywebsite/
  changed_when: false

- name: Enable httpd network connect boolean
  seboolean:
    name: httpd_can_network_connect
    state: yes
    persistent: yes
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| "SELinux 때문에 안 된다" → `setenforce 0` 또는 `disabled` | `ausearch -m avc`로 원인 파악 후 레이블/boolean 수정 |
| `chcon`으로 임시 레이블 변경 후 방치 | `semanage fcontext` + `restorecon`으로 영구 등록 |
| `audit2allow`로 모든 거부를 통째로 허용 | `.te` 파일 검토 후 최소 권한만 허용 |
| 비표준 포트를 열었는데 nginx 시작 안 됨 | `semanage port -a -t http_port_t -p tcp <포트>` |
| Docker 볼륨 마운트 후 Permission denied | `-v /path:/path:Z` 레이블 옵션 추가 |
| Disabled에서 Enforcing 전환 시 부팅 실패 | `touch /.autorelabel` 후 재부팅으로 레이블 재설정 |
| `targeted` 정책과 `mls` 정책 혼동 | 일반 서버는 `targeted`(기본), MLS는 다중 보안 레벨 환경용 |
