## 1. 개요

NFS(Network File System)와 AWS EFS(Elastic File System)는 네트워크를 통해 여러 서버가 동일한 파일시스템을 공유할 수 있게 해주는 기술이다.
EBS가 "한 서버에 붙이는 블록 장치"라면, NFS/EFS는 "여러 서버가 동시에 접근할 수 있는 공유 저장소"다.
실무에서 자주 겪는 혼란 중 하나가 **마운트 후 권한(chmod)과 소유자(chown)가 변경되지 않는 것처럼 보이는 현상**인데, 이는 NFS의 UID/GID 매핑 방식과 서버 측 권한 모델을 이해하지 못해서 발생한다.

> 관련 문서: `linux-fstab.md`, `linux-file-permissions.md`, `linux-volume-mount.md`

---

## 2. NFS 기초 개념

### 2.1 NFS란?

NFS는 클라이언트-서버 구조로 동작한다. 서버(NFS Server 또는 EFS)가 디렉토리를 "export"하면, 클라이언트가 그것을 네트워크를 통해 로컬 경로처럼 마운트한다.

```
[NFS Server / EFS]              [EC2 클라이언트 A]       [EC2 클라이언트 B]
/exports/shared  ─────────────►  /mnt/shared         /mnt/shared
(실제 데이터 저장)                (마운트 포인트)        (같은 데이터 접근)
```

**핵심 원리**: 파일의 메타데이터(권한, 소유자)는 **서버에 저장**된다. 클라이언트가 `ls -la`를 실행하면 서버에서 UID/GID 숫자를 받아와서 로컬 `/etc/passwd`로 이름을 변환해 보여줄 뿐이다.

### 2.2 NFS 버전 비교

| 항목 | NFSv3 | NFSv4 |
|---|---|---|
| 상태 관리 | Stateless (서버 재시작 후 자동 복구) | Stateful (세션 유지) |
| 포트 | 여러 포트 (portmapper 필요) | 단일 포트 2049 |
| 인증 | IP 기반 | Kerberos 지원, ID 도메인 매핑 |
| 잠금(Lock) | 별도 lockd 데몬 | 프로토콜 내장 |
| ACL | 제한적 | 풍부한 ACL 지원 |
| EFS 기본 | - | NFSv4.1 사용 |

---

## 3. 권한 동작 원리 (가장 중요)

### 3.1 왜 chown/chmod가 "안 되는 것처럼" 느껴지는가?

NFS는 **UID/GID 숫자**로 소유권을 관리한다. 이름(username)이 아니다.

```
서버에서 파일 소유자: UID=1000 → 서버의 /etc/passwd에서 "appuser"
클라이언트에서 보기:  UID=1000 → 클라이언트의 /etc/passwd에서 누구?
  - 클라이언트에 UID=1000인 사용자가 없으면 → 숫자 "1000"으로 표시
  - 클라이언트에 UID=1000이 "ec2-user"이면 → "ec2-user"로 표시 (잘못된 매핑!)
```

**실제 시나리오:**

```bash
# [서버] appuser(UID=1000)가 파일 생성
touch /exports/shared/data.txt
ls -la /exports/shared/data.txt
# -rw-r--r-- 1 appuser appuser 0 Jan 1 00:00 data.txt

# [클라이언트 A] - UID=1000이 "ec2-user"로 매핑된 경우
ls -la /mnt/shared/data.txt
# -rw-r--r-- 1 ec2-user ec2-user 0 Jan 1 00:00 data.txt  ← 이름만 달리 보임

# [클라이언트 B] - UID=1000 사용자가 없는 경우
ls -la /mnt/shared/data.txt
# -rw-r--r-- 1 1000 1000 0 Jan 1 00:00 data.txt  ← 숫자로 표시
```

### 3.2 root_squash: root가 root가 아닌 이유

NFS의 핵심 보안 기능이 **root_squash**다. 클라이언트의 root(UID=0)를 서버에서 신뢰하지 않고 `nfsnobody`(또는 `nobody`)로 매핑한다.

```bash
# 클라이언트에서 root로 파일 생성 시도
sudo touch /mnt/shared/root-file.txt
ls -la /mnt/shared/root-file.txt
# -rw-r--r-- 1 nfsnobody nfsnobody 0 Jan 1 00:00 root-file.txt
# root가 만들었지만 nfsnobody 소유!

# 그 결과: root로도 삭제 불가 (Permission denied)
sudo rm /mnt/shared/root-file.txt
# rm: cannot remove '/mnt/shared/root-file.txt': Permission denied
```

| 옵션 | 동작 |
|---|---|
| `root_squash` (기본값) | 클라이언트 root → `nfsnobody`로 매핑 |
| `no_root_squash` | 클라이언트 root = 서버 root (위험, 내부망에서만) |
| `all_squash` | 모든 사용자 → `nfsnobody`로 매핑 |
| `anonuid=UID` | squash 시 지정한 UID로 매핑 |

### 3.3 마운트 포인트 자체의 권한

마운트 포인트 디렉토리의 권한은 **마운트 후 NFS 서버의 export 루트 디렉토리 권한**으로 덮어씌워진다.

```bash
# 마운트 전
mkdir /mnt/shared
ls -ld /mnt/shared
# drwxr-xr-x 2 root root 6 Jan 1 00:00 /mnt/shared

# 마운트 후 - 서버의 export 디렉토리 권한으로 바뀜
mount -t nfs nfs-server:/exports/shared /mnt/shared
ls -ld /mnt/shared
# drwxr-xr-x 2 appuser appuser 4096 Jan 1 00:00 /mnt/shared
# ← 서버의 export 루트 소유자/권한이 반영됨
```

**이것이 "처음 만든 권한이 바뀌지 않는 것처럼 보이는" 원인이다.**
실제로는 서버의 권한이 그대로 유지되고 있는 것이다. 클라이언트에서 chmod/chown을 해도:
1. 클라이언트가 서버에 변경 요청을 보냄
2. 서버가 해당 클라이언트 UID의 권한을 확인
3. 권한이 없으면 거부 → 클라이언트에서는 "변경 안 됨"처럼 보임

---

## 4. AWS EFS 연결

### 4.1 EFS 개요

EFS는 AWS가 관리하는 완전 관리형 NFSv4.1 서비스다.

```
                    ┌─────────────────────┐
                    │        EFS          │
                    │  (NFSv4.1 서버)     │
                    │  자동 확장/축소     │
                    └──────────┬──────────┘
                               │ 포트 2049 (NFS)
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
    [EC2 ap-northeast-2a] [EC2 ap-northeast-2b] [EC2 ap-northeast-2c]
    Mount Target IP:       Mount Target IP:      Mount Target IP:
    10.0.1.x               10.0.2.x              10.0.3.x
```

각 AZ마다 **Mount Target**을 생성해야 한다. Mount Target은 EFS와 EC2 간 네트워크 접점이다.

### 4.2 EFS 마운트 준비

```bash
# EFS 마운트 헬퍼 설치 (amazon-efs-utils)
# Amazon Linux 2/2023
sudo yum install -y amazon-efs-utils

# Ubuntu
sudo apt-get install -y amazon-efs-utils
# 또는 nfs-common으로 대체 가능
sudo apt-get install -y nfs-common
```

### 4.3 EFS 마운트 방법 3가지

```bash
# 방법 1: EFS 마운트 헬퍼 (권장 - TLS 암호화 + 자동 재연결)
sudo mount -t efs -o tls fs-12345678:/ /mnt/efs
# fs-12345678은 EFS 파일시스템 ID

# 방법 2: NFS 직접 마운트 (Mount Target DNS 사용)
sudo mount -t nfs4 \
  -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
  fs-12345678.efs.ap-northeast-2.amazonaws.com:/ /mnt/efs

# 방법 3: IP로 직접 마운트 (DNS 없을 때)
sudo mount -t nfs4 \
  -o nfsvers=4.1 \
  10.0.1.100:/ /mnt/efs
```

### 4.4 /etc/fstab 영구 마운트 등록

```bash
# EFS 마운트 헬퍼 사용
fs-12345678:/ /mnt/efs efs _netdev,tls 0 0

# NFS 직접 사용
fs-12345678.efs.ap-northeast-2.amazonaws.com:/ /mnt/efs nfs4 \
  nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,_netdev 0 0
```

> **중요**: `_netdev` 옵션은 반드시 포함해야 한다. 네트워크가 올라온 후 마운트하도록 순서를 보장한다. 없으면 부팅 시 네트워크 미연결 상태에서 마운트를 시도해 부팅 실패가 발생할 수 있다.

---

## 5. EFS 권한 설정 실전 패턴

### 5.1 EFS 초기 권한 문제 해결

EFS를 처음 마운트하면 루트 디렉토리가 `root:root 755`다. 일반 사용자는 쓸 수 없다.

```bash
# 마운트 직후 상태 확인
ls -ld /mnt/efs
# drwxr-xr-x 2 root root 6144 Jan 1 00:00 /mnt/efs
# ← root만 쓰기 가능

# 해결 방법 1: 공유 디렉토리 생성 후 권한 변경
sudo mkdir /mnt/efs/shared
sudo chown ec2-user:ec2-user /mnt/efs/shared
sudo chmod 755 /mnt/efs/shared

# 해결 방법 2: 그룹 쓰기 허용
sudo chmod 775 /mnt/efs
sudo chown root:appgroup /mnt/efs
# appgroup에 속한 모든 사용자가 쓸 수 있음

# 해결 방법 3: sticky bit + 777 (공용 업로드 폴더)
sudo chmod 1777 /mnt/efs/uploads
# 누구나 쓰지만 자신의 파일만 삭제 가능
```

### 5.2 여러 서버가 같은 EFS를 쓸 때 UID 동기화

**가장 흔한 실수**: 서버마다 같은 이름의 계정이 다른 UID를 갖는 경우.

```bash
# 서버 A
id appuser
# uid=1000(appuser) gid=1000(appuser)

# 서버 B (자동 생성된 경우 UID가 다를 수 있음)
id appuser
# uid=1001(appuser) gid=1001(appuser)

# 결과: 서버 A가 만든 파일을 서버 B의 appuser가 소유자로 인식 못 함
```

**해결책: UID/GID를 명시적으로 지정해서 계정 생성**

```bash
# 모든 서버에서 동일 UID/GID로 계정 생성
sudo groupadd -g 1500 appgroup
sudo useradd -u 1500 -g 1500 -m appuser

# 이미 존재하는 계정의 UID 변경
sudo usermod -u 1500 appuser
sudo groupmod -g 1500 appgroup
# 기존 파일의 소유권도 함께 변경
sudo find / -user [기존UID] -exec chown -h 1500 {} \;
```

**Ansible로 UID 일관성 보장:**

```yaml
# roles/common/tasks/users.yml
- name: 공유 그룹 생성 (GID 고정)
  group:
    name: appgroup
    gid: 1500
    state: present

- name: 공유 사용자 생성 (UID 고정)
  user:
    name: appuser
    uid: 1500
    group: appgroup
    create_home: yes
    state: present
```

### 5.3 EFS 액세스 포인트 (권장 방식)

액세스 포인트는 EFS의 특정 경로를 특정 UID/GID로 자동 매핑하는 AWS 기능이다.
클라이언트의 실제 UID와 무관하게 **항상 지정된 UID/GID로 접근**한다.

```
EFS 파일시스템
└── /                    (root)
    ├── /app-data        ← 액세스 포인트 A: UID=1000, GID=1000
    └── /log-data        ← 액세스 포인트 B: UID=2000, GID=2000
```

```bash
# 액세스 포인트로 마운트
sudo mount -t efs \
  -o tls,accesspoint=fsap-12345678 \
  fs-12345678:/ /mnt/app-data

# fstab 등록
fs-12345678:/ /mnt/app-data efs _netdev,tls,accesspoint=fsap-12345678 0 0
```

**액세스 포인트 Terraform 예제:**

```hcl
resource "aws_efs_file_system" "app" {
  creation_token = "app-efs"
  encrypted      = true

  tags = {
    Name = "app-efs"
  }
}

resource "aws_efs_access_point" "app_data" {
  file_system_id = aws_efs_file_system.app.id

  # 이 액세스 포인트로 마운트하는 클라이언트는 항상 이 UID/GID로 동작
  posix_user {
    uid = 1000
    gid = 1000
  }

  # 마운트 시 자동으로 이 경로를 루트로 인식 (없으면 생성)
  root_directory {
    path = "/app-data"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "755"
    }
  }
}

resource "aws_efs_mount_target" "az_a" {
  file_system_id  = aws_efs_file_system.app.id
  subnet_id       = aws_subnet.private_a.id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_security_group" "efs" {
  name   = "efs-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]  # EC2 SG에서만 허용
  }
}
```

---

## 6. NFS 서버 직접 구성 (온프레미스/자체 구축)

### 6.1 NFS 서버 설치 및 설정

```bash
# RHEL/Amazon Linux
sudo yum install -y nfs-utils
sudo systemctl enable --now nfs-server

# Ubuntu
sudo apt-get install -y nfs-kernel-server
sudo systemctl enable --now nfs-server
```

### 6.2 /etc/exports 설정

```bash
# /etc/exports 파일 구조
# 디렉토리    클라이언트(옵션)
/exports/shared   10.0.0.0/24(rw,sync,no_subtree_check,root_squash)
/exports/readonly 10.0.1.0/24(ro,sync,no_subtree_check)
/exports/internal 10.0.2.10(rw,sync,no_root_squash)  # 신뢰된 서버만

# exports 적용
sudo exportfs -ra   # 재로드
sudo exportfs -v    # 현재 export 목록 확인
```

**주요 옵션 설명:**

| 옵션 | 설명 |
|---|---|
| `rw` / `ro` | 읽기-쓰기 / 읽기 전용 |
| `sync` | 쓰기 완료 후 응답 (안전, 느림) |
| `async` | 버퍼에 기록 후 바로 응답 (빠름, 데이터 손실 위험) |
| `root_squash` | 클라이언트 root → nobody 매핑 (기본값) |
| `no_root_squash` | 클라이언트 root = 서버 root |
| `all_squash` | 모든 사용자 → nobody 매핑 |
| `anonuid=N` | squash 시 사용할 UID 지정 |
| `anongid=N` | squash 시 사용할 GID 지정 |
| `no_subtree_check` | 서브트리 검사 비활성화 (성능 향상, 권장) |
| `fsid=0` | NFSv4 루트 export에 사용 |

### 6.3 클라이언트에서 마운트

```bash
# 사용 가능한 export 목록 확인
showmount -e nfs-server-ip

# 마운트
sudo mount -t nfs4 nfs-server-ip:/exports/shared /mnt/shared

# 마운트 옵션 상세 지정
sudo mount -t nfs4 \
  -o rw,hard,intr,rsize=8192,wsize=8192,timeo=14 \
  nfs-server-ip:/exports/shared /mnt/shared
```

**클라이언트 마운트 옵션:**

| 옵션 | 설명 |
|---|---|
| `hard` | 서버 무응답 시 무한 재시도 (데이터 일관성 보장) |
| `soft` | 재시도 후 에러 반환 (응답성 우선) |
| `intr` | hard 모드에서 Ctrl+C로 중단 허용 |
| `timeo=N` | 재시도 대기 시간 (단위: 0.1초) |
| `retrans=N` | 재시도 횟수 |
| `rsize/wsize` | 읽기/쓰기 블록 크기 (클수록 빠름, 최대 1M) |
| `noresvport` | 비특권 포트 사용 허용 (EFS 필수) |
| `_netdev` | 네트워크 준비 후 마운트 (fstab 필수) |

---

## 7. 권한 문제 트러블슈팅

### 7.1 진단 흐름

```bash
# 1. 현재 마운트 상태 확인
mount | grep nfs
# nfs-server:/exports/shared on /mnt/shared type nfs4 (rw,relatime,...)

# 2. 내 UID/GID 확인
id
# uid=1000(ec2-user) gid=1000(ec2-user) groups=1000(ec2-user)

# 3. 파일 소유자 확인 (숫자로)
ls -lan /mnt/shared/
# -rw-r--r-- 1 1000 1000 1024 Jan 1 00:00 data.txt
# -rw-r--r-- 1 1500 1500  512 Jan 1 00:00 other.txt

# 4. 서버 측 export 옵션 확인 (서버에서 실행)
sudo exportfs -v
# /exports/shared 10.0.0.0/24(rw,sync,wdelay,root_squash,...)

# 5. 실제 접근 테스트
sudo -u ec2-user touch /mnt/shared/test.txt
# Permission denied → 권한 문제
# 성공 → 정상
```

### 7.2 흔한 문제와 해결책

**문제 1: Permission denied - root임에도 파일 생성 불가**

```bash
# 원인: root_squash 동작 중
# 확인: 서버의 export 설정
cat /etc/exports | grep root_squash

# 해결 1: 서버에서 특정 경로에 no_root_squash 적용 (신뢰된 클라이언트만)
# /exports/admin 10.0.0.5(rw,sync,no_root_squash)
sudo exportfs -ra

# 해결 2: 일반 사용자 소유의 하위 디렉토리 사용
sudo mkdir /mnt/shared/myapp
sudo chown 1000:1000 /mnt/shared/myapp  # 서버에서 실행
```

**문제 2: 파일 소유자가 숫자로 표시**

```bash
# 원인: 클라이언트에 해당 UID의 사용자가 없음
ls -la /mnt/shared/
# -rw-r--r-- 1 1500 1500 0 data.txt  ← 이름 없이 숫자만

# 해결: 클라이언트에 동일 UID로 사용자 생성
sudo useradd -u 1500 appuser
ls -la /mnt/shared/
# -rw-r--r-- 1 appuser appuser 0 data.txt  ← 이름으로 표시
```

**문제 3: chown 명령이 실패 (클라이언트에서)**

```bash
sudo chown appuser /mnt/shared/data.txt
# chown: changing ownership of '/mnt/shared/data.txt': Operation not permitted

# 원인 1: root_squash로 인해 root 권한이 없음
# 원인 2: 현재 사용자가 해당 파일의 소유자가 아님
# NFS에서 chown은 파일 소유자이거나 서버 측 권한이 있어야 가능

# 해결: 서버에서 직접 chown 실행
# 서버 접속 후
sudo chown appuser:appgroup /exports/shared/data.txt
```

**문제 4: 마운트 후 디렉토리 권한이 예상과 다름**

```bash
# 현상: mkdir로 만든 마운트 포인트가 마운트 후 다른 권한으로 보임
ls -ld /mnt/shared  # 마운트 전: drwxr-xr-x root root
mount ...
ls -ld /mnt/shared  # 마운트 후: drwxrwxr-x appuser appgroup

# 원인: NFS는 서버 export 디렉토리의 권한을 그대로 표시
# 로컬 마운트 포인트의 권한은 마운트 중에는 숨겨짐 (마운트 해제 시 복원)

# 해결: 서버 측 export 루트 디렉토리 권한을 원하는 대로 설정
# 서버에서:
sudo chmod 755 /exports/shared
sudo chown root:appgroup /exports/shared
```

### 7.3 NFSv4 ID 도메인 불일치 문제

NFSv4에서는 UID/GID 대신 `user@domain` 형식을 사용한다. 도메인 설정이 맞지 않으면 모든 파일이 `nobody`로 보인다.

```bash
# 증상: 모든 파일 소유자가 nobody로 표시
ls -la /mnt/efs/
# drwxr-xr-x 2 nobody nobody 4096 /mnt/efs/

# 원인 확인: /etc/idmapd.conf 도메인 설정
cat /etc/idmapd.conf
# [General]
# Domain = localdomain  ← 서버와 클라이언트가 달라서 문제

# 해결: 서버와 클라이언트 모두 동일한 도메인으로 설정
sudo vi /etc/idmapd.conf
# [General]
# Domain = example.com  ← 양쪽 동일하게

sudo systemctl restart nfs-idmapd
# 또는 EFS의 경우 amazon-efs-utils가 자동 처리
```

---

## 8. 성능 튜닝

### 8.1 마운트 옵션 최적화

```bash
# 처리량 최대화 (대용량 파일 처리)
mount -t nfs4 \
  -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
  server:/path /mnt/nfs

# 지연 최소화 (소용량 파일 다수)
mount -t nfs4 \
  -o nfsvers=4.1,rsize=65536,wsize=65536,hard,timeo=150,retrans=3,noac \
  server:/path /mnt/nfs
# noac: 속성 캐시 비활성화 → 일관성 강화, 성능 저하

# EFS 권장 옵션 (AWS 공식)
mount -t efs \
  -o tls,_netdev \
  fs-12345678:/ /mnt/efs
```

### 8.2 EFS 처리량 모드

| 모드 | 특징 | 적합한 경우 |
|---|---|---|
| Bursting (기본) | 저장 용량에 비례한 기본 처리량 + 크레딧 버스트 | 간헐적 대용량 I/O |
| Provisioned | 용량과 무관하게 처리량 지정 | 지속적 고성능 필요 |
| Elastic (권장) | 자동으로 필요한 만큼 처리량 제공 | 예측 불가한 워크로드 |

---

## 3. 자주 하는 실수

| 실수 | 문제 | 올바른 방법 |
|---|---|---|
| fstab에 `_netdev` 누락 | 부팅 시 NFS 마운트 실패로 부팅 멈춤 | `_netdev` 옵션 반드시 추가 |
| 서버마다 다른 UID로 계정 생성 | 파일 소유자가 서버마다 다르게 보임 | `useradd -u 고정UID`로 통일 |
| 클라이언트 root로 파일 생성 후 관리 시도 | root_squash로 인해 삭제/수정 불가 | 일반 사용자 소유 디렉토리 사용 |
| EFS SG에서 포트 2049 미개방 | 마운트 타임아웃 | EC2 SG → EFS SG 인바운드 2049 허용 |
| `soft` 마운트 + DB 데이터 저장 | 네트워크 불안정 시 데이터 손실 | DB 데이터는 `hard` 마운트 사용 |
| NFSv4 idmapd 도메인 불일치 | 모든 파일이 `nobody:nobody`로 표시 | 서버/클라이언트 `/etc/idmapd.conf` Domain 동일하게 설정 |
| EFS 마운트 후 루트에 직접 데이터 저장 | 권한 문제, 구조 혼란 | 액세스 포인트 또는 하위 디렉토리 생성 후 사용 |
| async 옵션 사용 | 서버 장애 시 버퍼 데이터 유실 | 중요 데이터는 `sync` 사용 |
