## 1. 개요

파일시스템 레이아웃 표준을 정의하지 않으면 서버마다 데이터 경로가 달라 자동화 스크립트가 깨지고, 이관 작업 시 파일 위치를 파악하는 데 시간을 낭비한다.
본 문서는 서비스 운영, 데이터 이관, EFS/NAS 공유 스토리지 연계 환경에서 일관된 파일시스템 레이아웃 표준을 정의한다.

---

## 2. 디렉토리 용도별 표준

### 2.1 로컬 서버 디렉토리 구조

```
/
├── /app/                         # 애플리케이션 루트 (표준 마운트 포인트)
│   └── {service-name}/           # 서비스별 격리
│       ├── current/              # 현재 배포본 (심볼릭 링크 권장)
│       ├── releases/             # 배포 이력 (최근 5개 유지)
│       └── shared/               # 배포 간 공유 파일 (logs, config)
│
├── /data/                        # 영구 데이터 루트 (EBS/볼륨 마운트 권장)
│   └── {service-name}/           # 서비스별 데이터
│       ├── db/                   # 데이터베이스 파일
│       ├── files/                # 업로드 파일 등
│       └── backup/               # 로컬 백업 (임시)
│
├── /transfer/                    # ★ 이관 전용 임시 영역 (아래 섹션 참조)
│
├── /mnt/                         # OS 표준 마운트 포인트
│   ├── efs/                      # EFS 마운트 (아래 섹션 참조)
│   └── data/                     # 추가 EBS 볼륨
│
├── /var/log/{service-name}/      # 서비스 로그 (logrotate 필수)
└── /tmp/                         # 임시 파일 (재부팅 시 초기화, 민감 데이터 금지)
```

### 2.2 디렉토리별 권한 기준

| 경로 | 소유자 | 권한 | 이유 |
|---|---|---|---|
| `/app/{service}/` | `root:root` | `755` | 배포 디렉토리는 root 소유 |
| `/app/{service}/shared/logs/` | `{service-user}:root` | `750` | 서비스 계정이 로그 기록 |
| `/data/{service}/` | `{service-user}:{service-group}` | `750` | 서비스 계정만 접근 |
| `/transfer/` | `root:transfer-group` | `1770` | Sticky bit + 그룹 쓰기 |
| `/mnt/efs/{share}/` | 용도별 | 아래 섹션 참조 | EFS 설정에 따름 |
| `/var/log/{service}/` | `{service-user}:adm` | `750` | 로그 분석 그룹(`adm`) 읽기 허용 |

---

## 3. 이관(Migration) 전용 폴더 표준

### 3.1 설계 원칙

이관 폴더는 **임시 거점**이다. 완료 후 반드시 정리한다.

```
/transfer/
├── incoming/          # 외부에서 수신한 데이터 (검증 전)
│   └── {YYYYMMDD}-{source}-{description}/
│       ├── raw/       # 원본 데이터 (수정 금지)
│       ├── manifest/  # 파일 목록 + 체크섬
│       └── .lock      # 전송 중 표시 (완료 시 삭제)
│
├── outgoing/          # 외부로 전송할 데이터 (검증 완료)
│   └── {YYYYMMDD}-{target}-{description}/
│
├── staging/           # 검증/변환 작업 공간
│   └── {YYYYMMDD}-{task}/
│
└── archive/           # 이관 완료 후 30일 보존 → 삭제 또는 S3 이동
    └── {YYYYMMDD}-{description}.tar.gz
```

### 3.2 이관 폴더 생성 절차

```bash
# 이관 작업 시작 시 표준 디렉토리 생성
TRANSFER_DATE=$(date +%Y%m%d)
TRANSFER_NAME="legacy-db-migration"

mkdir -p /transfer/incoming/${TRANSFER_DATE}-${TRANSFER_NAME}/{raw,manifest}
mkdir -p /transfer/staging/${TRANSFER_DATE}-${TRANSFER_NAME}
mkdir -p /transfer/archive

# 소유권 설정 (이관 담당자 그룹)
chown -R root:transfer-group /transfer/incoming/${TRANSFER_DATE}-${TRANSFER_NAME}
chmod -R 2770 /transfer/incoming/${TRANSFER_DATE}-${TRANSFER_NAME}
# SetGID bit(2xxx): 하위 파일/디렉토리가 자동으로 그룹 상속

# 전송 중 잠금 파일 생성
touch /transfer/incoming/${TRANSFER_DATE}-${TRANSFER_NAME}/.lock
```

### 3.3 체크섬 검증 (필수)

```bash
# 송신 측: 체크섬 생성
find /transfer/incoming/20260422-legacy-db/raw -type f \
  | sort | xargs sha256sum > /transfer/incoming/20260422-legacy-db/manifest/checksums.sha256

# 수신 측: 검증
cd /transfer/incoming/20260422-legacy-db
sha256sum --check manifest/checksums.sha256
# 출력: 모든 파일 OK 확인 후 .lock 제거

rm .lock
echo "$(date -Iseconds) 검증 완료" >> manifest/transfer.log
```

### 3.4 이관 완료 후 정리

```bash
# 완료 후 압축 보존 (30일)
tar -czf /transfer/archive/$(date +%Y%m%d)-legacy-db-migration.tar.gz \
  -C /transfer/incoming 20260422-legacy-db/manifest/

# 원본 디렉토리 삭제
rm -rf /transfer/incoming/20260422-legacy-db
rm -rf /transfer/staging/20260422-legacy-db-migration

# 30일 지난 아카이브 자동 삭제 (crontab 등록)
find /transfer/archive -name "*.tar.gz" -mtime +30 -delete
```

---

## 4. EFS (Elastic File System) 마운트 표준

### 4.1 마운트 포인트 네이밍 규칙

```
/mnt/efs/{용도}/{환경}/
```

| 예시 경로 | 설명 |
|---|---|
| `/mnt/efs/shared/prod/` | 운영 환경 공통 공유 스토리지 |
| `/mnt/efs/media/prod/` | 미디어 파일 전용 EFS |
| `/mnt/efs/config/prod/` | 설정 파일 공유 (민감 정보 금지) |
| `/mnt/efs/backup/prod/` | 백업 전용 EFS |

### 4.2 EFS 마운트 구성 (/etc/fstab)

```bash
# /etc/fstab 표준 설정
# {efs-id}.efs.{region}.amazonaws.com:/ {마운트포인트} efs {옵션} 0 0

fs-0abc12345.efs.ap-northeast-2.amazonaws.com:/ \
  /mnt/efs/shared/prod \
  efs \
  _netdev,tls,iam,noresvport,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
  0 0
```

| 옵션 | 설명 | 권장 여부 |
|---|---|---|
| `tls` | 전송 암호화 | **필수** |
| `iam` | IAM 인증 (EC2 인스턴스 프로필 활용) | **권장** |
| `_netdev` | 네트워크 준비 후 마운트 | **필수** |
| `noresvport` | TCP 포트 재사용 (재연결 속도 향상) | 권장 |
| `hard` | NFS 오류 시 무한 재시도 (데이터 무결성) | 권장 |
| `timeo=600` | 타임아웃 60초 (기본값보다 낮춤) | 환경별 조정 |

### 4.3 EFS 디렉토리별 권한 구조

EFS는 POSIX 권한을 따른다. **Access Point**를 활용하면 서비스별 루트 격리가 가능하다.

```
EFS 루트 (root:root, 755)
├── /shared/           → Access Point A: uid=1000, gid=1000, root path=/shared
│   ├── uploads/       chmod 2775 (SetGID)
│   └── reports/       chmod 750
│
├── /backup/           → Access Point B: uid=0, gid=backup-group
│   └── daily/         chmod 770
│
└── /config/           → Access Point C: uid=0, gid=ops-team, 750
```

```bash
# Access Point 생성 (AWS CLI)
aws efs create-access-point \
  --file-system-id fs-0abc12345 \
  --posix-user Uid=1000,Gid=1000 \
  --root-directory "Path=/shared,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=755}" \
  --tags Key=Service,Value=app-api Key=Env,Value=prod

# Access Point로 마운트
mount -t efs \
  -o tls,iam,accesspoint=fsap-0xyz98765 \
  fs-0abc12345 /mnt/efs/shared/prod
```

### 4.4 EFS 운영 주의사항

```bash
# EFS 성능 모드 확인 (변경 불가, 생성 시 결정)
aws efs describe-file-systems --file-system-id fs-0abc12345 \
  --query 'FileSystems[0].{Mode:PerformanceMode,Throughput:ThroughputMode}'

# Burst vs Provisioned Throughput
# - 소규모/간헐적 사용: Bursting (기본)
# - 대용량/지속 사용: Provisioned (사전 지정)

# EFS 마운트 상태 확인
mount | grep efs
df -hT /mnt/efs/shared/prod

# 연결된 클라이언트 수 확인 (CloudWatch)
aws cloudwatch get-metric-statistics \
  --namespace AWS/EFS \
  --metric-name ClientConnections \
  --dimensions Name=FileSystemId,Value=fs-0abc12345 \
  --start-time $(date -u -d '1 hour ago' +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) \
  --period 300 --statistics Sum
```

---

## 5. NAS 마운트 표준 (NFS 기반)

### 5.1 마운트 포인트 규칙

```
/mnt/nas/{nas-서버명}/{공유명}/
```

```
/mnt/nas/
├── nas01/
│   ├── backup/        # NAS 서버 1의 backup 공유
│   └── archive/
└── nas02/
    └── media/
```

### 5.2 NFS 마운트 설정 (/etc/fstab)

```bash
# NFSv4 권장 (보안 강화, Kerberos 연계 가능)
nas01.internal:/backup  /mnt/nas/nas01/backup  nfs4  \
  _netdev,rw,hard,intr,rsize=1048576,wsize=1048576,timeo=600,retrans=3,sec=sys  0 0

# 읽기 전용 마운트 (아카이브용)
nas01.internal:/archive  /mnt/nas/nas01/archive  nfs4  \
  _netdev,ro,hard,intr,rsize=1048576,timeo=600  0 0
```

### 5.3 UID/GID 일관성 (NAS 환경의 핵심)

NFS는 UID/GID 숫자 기반으로 권한을 적용한다. **서버마다 UID가 다르면 권한 오류 발생.**

```bash
# 문제 상황: 서버 A(app-api uid=501) vs 서버 B(app-api uid=502)
# NAS에 서버 A가 쓴 파일을 서버 B에서 읽으면 권한 오류

# 해결 1: 고정 UID로 계정 생성 (모든 서버 동일)
# → 계정 관리 표준(linux-account-standards.md) 2.2 참조

# 해결 2: NFS ID 매핑 사용 (idmapd)
# /etc/idmapd.conf
# [General]
# Domain = company.internal   # 동일 도메인으로 UID 매핑
# [Mapping]
# Nobody-User = nobody
# Nobody-Group = nobody

# 해결 3: all_squash 옵션 (보안 낮음, 비권장)
# NAS 서버: exports 설정에서 all_squash,anonuid=1000,anongid=1000

# 현재 NFS 마운트의 UID 매핑 상태 확인
nfsstat -c
rpcinfo -p nas01.internal
```

---

## 6. 스토리지 계층별 사용 기준 요약

| 계층 | 사용 케이스 | 예시 경로 | 비고 |
|---|---|---|---|
| **로컬 디스크** | OS, 애플리케이션 바이너리 | `/app/`, `/usr/` | 빠름, 서버 종속 |
| **EBS (추가 볼륨)** | 서비스 데이터, DB 데이터 | `/data/{service}/` | 단일 서버, 스냅샷 지원 |
| **EFS** | 다중 서버 공유 파일, 배포 공유 | `/mnt/efs/shared/` | 다중 마운트, POSIX 권한 |
| **NAS (NFS)** | 온프레미스 대용량 공유 스토리지 | `/mnt/nas/nas01/` | UID 일관성 필수 |
| **S3 (마운트)** | 아카이브, 비정형 대용량 | `/mnt/s3/{bucket}/` | mountpoint-s3, 고지연 |
| **이관 임시 영역** | 데이터 이관 작업 | `/transfer/` | 작업 후 반드시 정리 |
| **/tmp** | 프로세스 임시 파일 | `/tmp/` | 재부팅 초기화, 민감 데이터 금지 |

---

## 7. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `/tmp`에 이관 데이터 저장 → 재부팅 시 소실 | `/transfer/incoming/` 사용, 완료 후 정리 |
| EFS 마운트 시 `tls` 옵션 생략 → 평문 전송 | `tls` 옵션 필수 (전송 암호화) |
| 이관 완료 후 `/transfer` 정리 안 함 → 디스크 풀 | 30일 보존 후 삭제 cron 등록 |
| NFS 마운트 시 `_netdev` 생략 → 부팅 시 hang | `/etc/fstab`에 `_netdev` 필수 |
| EFS에 서비스별 격리 없이 공유 → 권한 혼재 | Access Point로 서비스별 루트 격리 |
| 이관 중 체크섬 검증 생략 → 데이터 손상 무감지 | `sha256sum` 검증 필수 (manifest 보존) |
| 여러 서버에서 동일 EBS 마운트 시도 | EBS는 단일 AZ 단일 인스턴스 — 다중 마운트는 EFS 사용 |
