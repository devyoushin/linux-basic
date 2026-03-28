## 1. 개요

AWS EC2에 EBS 볼륨을 추가하는 과정은 단순히 콘솔에서 "연결"을 누르는 것으로 끝나지 않는다.
물리적 연결(Attach) → 파티션 생성(선택) → 포맷(mkfs) → 마운트(mount) → 영구 등록(/etc/fstab) 의 5단계를 거쳐야 실제로 사용할 수 있다.
잘못된 fstab 설정은 부팅 실패로 이어지므로 각 단계를 정확히 이해하는 것이 중요하다.

> 관련 문서: `linux-lsblk.md`, `linux-fstab.md`

---

## 2. 전체 흐름 요약

```
[AWS 콘솔/CLI]          [EC2 인스턴스 내부]
EBS 볼륨 생성
    ↓
EC2에 Attach          → lsblk로 새 디바이스 확인
    ↓
                         파티션 생성 (fdisk/parted) ← 선택사항
    ↓
                         파일시스템 포맷 (mkfs.ext4 / mkfs.xfs)
    ↓
                         마운트 포인트 생성 (mkdir)
    ↓
                         임시 마운트 (mount) → 동작 확인
    ↓
                         /etc/fstab 등록 → 영구 마운트
    ↓
                         마운트 검증 (mount -a)
```

---

## 3. 단계별 실습

### 3.1 새 볼륨 확인 (lsblk)

EBS를 EC2에 Attach하면 디바이스 파일이 생성된다. 먼저 어떤 이름으로 잡혔는지 확인한다.

```bash
lsblk

# 출력 예시:
# NAME    MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
# xvda    202:0    0   20G  0 disk            ← 루트 볼륨
# └─xvda1 202:1    0   20G  0 part /
# xvdf    202:80   0  100G  0 disk            ← 새로 추가한 EBS (마운트 없음)

# 파일시스템 타입 및 UUID 포함 확인 (포맷 전이라 FSTYPE이 비어있음)
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID
```

**디바이스 이름 규칙:**
| 환경 | 이름 패턴 | 예시 |
|---|---|---|
| 구형 인스턴스 (Xen) | `/dev/xvd[f-z]` | `/dev/xvdf` |
| Nitro 인스턴스 (NVMe) | `/dev/nvme[0-9]n1` | `/dev/nvme1n1` |
| 물리 서버 (SATA/SAS) | `/dev/sd[a-z]` | `/dev/sdb` |

```bash
# NVMe 디바이스 상세 정보 (Nitro 인스턴스)
nvme list   # nvme-cli 패키지 필요: yum install nvme-cli

# 콘솔에서 /dev/sdf 로 연결했어도 실제로는 /dev/nvme1n1 로 잡힐 수 있음
# nvme id-ctrl /dev/nvme1n1 -v | grep sdf  로 매핑 확인 가능
```

### 3.2 파일시스템 포맷

> **주의**: 포맷은 기존 데이터를 전부 삭제한다. 반드시 신규 볼륨 또는 데이터 백업 후 진행한다.

```bash
# ext4 포맷 (범용, 대부분의 경우 적합)
mkfs.ext4 /dev/xvdf

# xfs 포맷 (대용량, Amazon Linux 2/RHEL 8+ 기본)
mkfs.xfs /dev/xvdf

# 포맷 후 UUID 확인 (fstab 등록에 사용)
blkid /dev/xvdf
# /dev/xvdf: UUID="a1b2c3d4-e5f6-7890-abcd-ef1234567890" TYPE="ext4"

# lsblk로도 확인 가능
lsblk -o NAME,UUID,FSTYPE /dev/xvdf
```

**ext4 vs xfs 선택 기준:**
| | ext4 | xfs |
|---|---|---|
| 안정성 | 매우 높음 | 높음 |
| 대용량 파일 | 좋음 | 더 좋음 (스트리밍 I/O) |
| 다수의 소규모 파일 | 좋음 | 보통 |
| 축소(shrink) | 가능 | 불가능 (확장만 가능) |
| Amazon Linux 2023 기본 | — | xfs |
| Ubuntu 기본 | ext4 | — |

### 3.3 마운트 포인트 생성 및 마운트

```bash
# 마운트 포인트 디렉토리 생성
mkdir -p /data
mkdir -p /var/lib/mysql   # DB 데이터용 예시

# 임시 마운트 (재부팅 시 사라짐 - 먼저 동작 확인용)
mount /dev/xvdf /data

# 마운트 확인
df -h /data
# Filesystem      Size  Used Avail Use% Mounted on
# /dev/xvdf        99G   61M   94G   1% /data

lsblk
# xvdf    202:80   0  100G  0 disk /data  ← MOUNTPOINT 표시
```

### 3.4 /etc/fstab 영구 등록

디바이스 이름(`/dev/xvdf`)은 재부팅 시 바뀔 수 있다. **반드시 UUID를 사용**한다.

```bash
# UUID 확인
UUID=$(blkid -s UUID -o value /dev/xvdf)
echo $UUID
# a1b2c3d4-e5f6-7890-abcd-ef1234567890

# fstab에 추가 (기존 내용 보존)
echo "UUID=${UUID}  /data  ext4  defaults,nofail  0  2" >> /etc/fstab
```

**fstab 옵션 설명:**
```
UUID=a1b2...  /data  ext4  defaults,nofail  0  2
│             │      │     │                │  └── fsck 순서 (0=생략, 1=루트, 2=그 외)
│             │      │     │                └───── dump 백업 (0=생략)
│             │      │     └─────────────────────── 마운트 옵션
│             │      └───────────────────────────── 파일시스템 타입
│             └──────────────────────────────────── 마운트 포인트
└────────────────────────────────────────────────── 디바이스 (UUID 권장)
```

**주요 마운트 옵션:**
| 옵션 | 설명 |
|---|---|
| `defaults` | rw, suid, dev, exec, auto, nouser, async 기본값 |
| `nofail` | 마운트 실패해도 부팅 계속 진행 (EBS 필수 옵션) |
| `noatime` | 읽기 시 접근 시간 업데이트 안 함 → I/O 성능 향상 |
| `ro` | 읽기 전용 마운트 |
| `noexec` | 실행 파일 실행 금지 (보안 강화) |

> **`nofail` 옵션은 AWS EBS에서 필수다.** EBS가 연결 안 된 상태로 부팅 시 이 옵션이 없으면 부팅이 멈춘다.

### 3.5 fstab 검증 (재부팅 전 반드시 실행)

```bash
# fstab의 모든 항목 마운트 시도 (오류 즉시 확인 가능)
mount -a

# 오류가 없으면 정상. 다시 마운트 상태 확인
df -h
lsblk
```

---

## 4. 볼륨 확장 (온라인 리사이즈)

AWS에서 EBS 볼륨 크기를 늘린 후 OS에도 반영하는 과정이다. **재부팅 없이 가능하다.**

```bash
# 1. AWS 콘솔/CLI에서 볼륨 크기 변경 후 EC2에서 확인
lsblk
# xvdf  202:80  0  200G  0 disk /data  ← 200G로 늘어남

# 2. 파일시스템이 파티션 위에 있다면 파티션 먼저 확장
# (직접 포맷한 경우 파티션 없으니 이 단계 생략)
growpart /dev/xvdf 1   # xvdf1 파티션 확장

# 3. 파일시스템 확장
# ext4:
resize2fs /dev/xvdf

# xfs (마운트된 상태에서 확장):
xfs_growfs /data       # 디바이스가 아닌 마운트 포인트로 지정

# 4. 확인
df -h /data
# Filesystem      Size  Used Avail Use% Mounted on
# /dev/xvdf       197G   61M  187G   1% /data   ← 확장됨
```

---

## 5. Terraform으로 EBS 볼륨 자동화

```hcl
resource "aws_ebs_volume" "data" {
  availability_zone = "ap-northeast-2a"
  size              = 100
  type              = "gp3"
  encrypted         = true

  tags = { Name = "app-data-volume" }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id
}

resource "aws_instance" "app" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "t3.medium"

  user_data = <<-EOF
    #!/bin/bash
    # NVMe 환경에서 디바이스 이름 자동 감지
    # /dev/sdf → /dev/nvme1n1 매핑 처리
    DEVICE=$(lsblk -o NAME,SERIAL | grep -i "$(aws ec2 describe-volumes \
      --volume-ids ${aws_ebs_volume.data.id} \
      --query 'Volumes[0].VolumeId' --output text | tr -d 'vol-')" \
      | awk '{print "/dev/"$1}')

    # 포맷 (신규 볼륨인 경우만)
    if ! blkid "$DEVICE" &>/dev/null; then
      mkfs.ext4 "$DEVICE"
    fi

    # 마운트
    mkdir -p /data
    UUID=$(blkid -s UUID -o value "$DEVICE")
    echo "UUID=${UUID} /data ext4 defaults,nofail 0 2" >> /etc/fstab
    mount -a
  EOF
}
```

---

## 6. 언마운트 및 볼륨 분리

```bash
# 마운트 해제 전 사용 중인 프로세스 확인
lsof /data           # /data 를 사용 중인 프로세스 목록
fuser -m /data       # 마운트 포인트 사용 중인 PID

# 프로세스 종료 후 언마운트
umount /data

# 강제 언마운트 (최후 수단)
umount -l /data      # lazy: 더 이상 새 접근 차단, 기존 I/O 완료 후 언마운트
umount -f /data      # force (NFS 등 원격 마운트에서 주로 사용)

# 언마운트 후 fstab에서도 해당 줄 제거
vi /etc/fstab

# AWS CLI로 볼륨 분리
aws ec2 detach-volume --volume-id vol-0123456789abcdef0
```

## 7. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| UUID 대신 `/dev/xvdf`로 fstab 등록 | `blkid`로 UUID 확인 후 등록 |
| `nofail` 옵션 누락 | EBS 볼륨은 항상 `nofail` 포함 |
| `mount -a` 검증 없이 재부팅 | fstab 수정 후 반드시 `mount -a` 실행 |
| 포맷 전 기존 볼륨인지 확인 안 함 | `lsblk -f` 또는 `blkid`로 FSTYPE 확인 |
| xfs 볼륨을 줄이려고 시도 | xfs는 확장만 가능, 축소 불가 |
| 사용 중 디바이스 강제 분리 | `lsof /mountpoint`로 프로세스 확인 후 종료 |
