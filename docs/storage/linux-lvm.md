# LVM (Logical Volume Manager) - 유연한 볼륨 관리

## 1. 개요

LVM은 물리 디스크를 추상화 계층으로 감싸 유연한 볼륨 관리를 제공하는 리눅스 서브시스템이다. 파티션 크기를 미리 고정하지 않고, 운영 중에 볼륨을 확장·축소·스냅샷·이동할 수 있다. 여러 EBS 볼륨을 하나의 논리 볼륨으로 합치거나, 디스크 공간이 부족할 때 서비스 중단 없이 온라인 확장이 가능해 클라우드 환경에서 특히 유용하다.

---

## 2. LVM 아키텍처

### 2.1 3계층 추상화 구조

```
┌─────────────────────────────────────────────────────┐
│                  애플리케이션 / 파일시스템             │
│              (ext4, xfs, /data 마운트포인트)          │
└────────────────────┬────────────────────────────────┘
                     │ 블록 I/O
┌────────────────────▼────────────────────────────────┐
│              LV (Logical Volume)                     │
│    /dev/vg_data/lv_app   /dev/vg_data/lv_log        │
└────────────────────┬────────────────────────────────┘
                     │ PE(Physical Extent) 매핑
┌────────────────────▼────────────────────────────────┐
│              VG (Volume Group)                       │
│                   vg_data                            │
│    [PE][PE][PE][PE][PE][PE][PE][PE][PE][PE]          │
└──────┬──────────────────────────────┬───────────────┘
       │                              │
┌──────▼──────┐                ┌──────▼──────┐
│  PV (xvdb)  │                │  PV (xvdc)  │
│  /dev/xvdb  │                │  /dev/xvdc  │
└─────────────┘                └─────────────┘

PV: 물리 볼륨 (디스크 또는 파티션)
VG: 볼륨 그룹 (PV들의 풀)
LV: 논리 볼륨 (실제 사용하는 블록 디바이스)
PE: Physical Extent (VG의 최소 할당 단위, 기본 4MB)
```

### 2.2 핵심 개념

| 용어 | 설명 | 기본값 |
|------|------|--------|
| PV (Physical Volume) | LVM이 관리하는 물리 장치 | - |
| VG (Volume Group) | 여러 PV를 묶은 스토리지 풀 | - |
| LV (Logical Volume) | VG에서 할당받은 논리 볼륨 | - |
| PE (Physical Extent) | PV의 최소 할당 블록 | 4MB |
| LE (Logical Extent) | LV의 최소 할당 블록 (PE와 1:1 매핑) | 4MB |

---

## 3. 기본 워크플로우

### 3.1 PV 생성

```bash
# 디스크 전체를 PV로 지정 (파티션 불필요)
pvcreate /dev/xvdb /dev/xvdc

# PV 정보 확인
pvs                        # 요약 정보
pvdisplay /dev/xvdb        # 상세 정보 (PE 크기, 총 PE 수 등)

# 출력 예시
# PV         VG      Fmt  Attr PSize  PFree
# /dev/xvdb  vg_data lvm2 a--  <50.00g    0
# /dev/xvdc  vg_data lvm2 a--  <50.00g    0
```

### 3.2 VG 생성

```bash
# 두 PV를 하나의 VG로 묶기
vgcreate vg_data /dev/xvdb /dev/xvdc

# PE 크기를 16MB로 변경 (대용량 LV에 적합)
vgcreate -s 16M vg_data /dev/xvdb /dev/xvdc

# VG 정보 확인
vgs                        # 요약: 총 크기, 사용 중, 여유
vgdisplay vg_data          # 상세: PE 수, UUID 등
```

### 3.3 LV 생성

```bash
# 절대 크기로 LV 생성
lvcreate -L 30G -n lv_app vg_data

# VG 여유 공간의 100%를 LV로 생성
lvcreate -l 100%FREE -n lv_log vg_data

# LV 정보 확인
lvs                        # 요약
lvdisplay /dev/vg_data/lv_app

# 블록 디바이스 경로 (두 경로 모두 동일)
# /dev/vg_data/lv_app
# /dev/mapper/vg_data-lv_app
```

### 3.4 파일시스템 생성 및 마운트

```bash
# ext4 파일시스템 생성
mkfs.ext4 /dev/vg_data/lv_app

# xfs 파일시스템 생성 (AWS EBS 권장)
mkfs.xfs /dev/vg_data/lv_log

# 마운트 포인트 생성 및 마운트
mkdir -p /app /var/log/app
mount /dev/vg_data/lv_app /app
mount /dev/vg_data/lv_log /var/log/app

# /etc/fstab에 영구 등록 (UUID 사용 권장)
blkid /dev/vg_data/lv_app
# /dev/vg_data/lv_app: UUID="a1b2c3d4-..." TYPE="ext4"

echo 'UUID=a1b2c3d4-... /app ext4 defaults 0 2' >> /etc/fstab
```

---

## 4. 온라인 볼륨 확장

LVM의 핵심 강점은 서비스 중단 없이 볼륨을 확장할 수 있다는 점이다.

### 4.1 VG에 PV 추가 후 LV 확장 (AWS EBS 추가 시)

```
시나리오: /app(30G)이 꽉 참 → 새 EBS 50G를 추가하여 확장

기존: [xvdb 50G] --VG--> [lv_app 30G][lv_log 20G]
추가: [xvdb 50G][xvdc 50G] --VG--> [lv_app 80G][lv_log 20G]
```

```bash
# 1. 새 EBS 볼륨 확인
lsblk                      # /dev/xvdc 확인

# 2. 새 디스크를 PV로 등록
pvcreate /dev/xvdc

# 3. VG에 새 PV 추가
vgextend vg_data /dev/xvdc

# 4. LV 확장 (50G 추가)
lvextend -L +50G /dev/vg_data/lv_app

# 또는 VG 여유 공간 전체를 LV에 추가
lvextend -l +100%FREE /dev/vg_data/lv_app

# 5. 파일시스템 확장 (마운트 상태에서 온라인 가능)
# ext4: resize2fs 사용
resize2fs /dev/vg_data/lv_app

# xfs: xfs_growfs 사용 (마운트 포인트 지정)
xfs_growfs /app

# 6. 확인
df -h /app
```

### 4.2 기존 PV(EBS) 크기 확장 시 (AWS EBS 볼륨 수정 후)

```bash
# AWS 콘솔에서 xvdb를 50G → 100G로 수정 후

# 1. 커널이 새 크기를 인식했는지 확인
lsblk                      # 100G로 보여야 함
# (인식 안 되면: echo 1 > /sys/block/xvdb/device/rescan)

# 2. PV 메타데이터 업데이트
pvresize /dev/xvdb

# 3. VG 여유 공간 확인
vgs                        # VFree가 늘어남

# 4. LV 확장 및 파일시스템 확장
lvextend -l +100%FREE /dev/vg_data/lv_app
resize2fs /dev/vg_data/lv_app  # ext4
```

---

## 5. LV 스냅샷

스냅샷은 백업 전 파일시스템을 일관된 상태로 고정하거나, 위험한 작업 전 롤백 포인트를 만드는 데 사용한다.

### 5.1 CoW(Copy-on-Write) 동작 원리

```
스냅샷 생성 시점:
  원본 LV:  [A][B][C][D][E]  ← 원래 데이터
  스냅샷:   [메타데이터만] ← 변경 전 블록의 주소 기록

블록 수정 시:
  원본 LV:  [A][B'][C][D][E]  ← B가 B'으로 변경됨
  스냅샷:   [B 원본 저장]      ← 수정 전 B를 스냅샷 영역에 복사

스냅샷 크기: 변경된 블록만큼 소비 → 스냅샷 볼륨이 가득 차면 무효화
```

### 5.2 스냅샷 생성 및 활용

```bash
# 스냅샷 생성 (원본 크기의 10~20% 권장)
lvcreate -L 5G -s -n lv_app_snap /dev/vg_data/lv_app

# 스냅샷 상태 확인 (Data% 가 100%에 가까우면 위험)
lvs -o +snap_percent
# LV           VG      Attr   LSize  Pool Origin  Data%
# lv_app_snap  vg_data swi-as  5.00g      lv_app  12.50

# 스냅샷으로 백업 수행
mkdir /mnt/snap
mount -o ro /dev/vg_data/lv_app_snap /mnt/snap
tar czf /backup/app_$(date +%Y%m%d).tar.gz /mnt/snap/
umount /mnt/snap

# 백업 후 스냅샷 제거
lvremove /dev/vg_data/lv_app_snap
```

### 5.3 스냅샷으로 롤백

```bash
# 서비스 중지 후 원본 LV를 스냅샷으로 복원
umount /app
lvconvert --merge /dev/vg_data/lv_app_snap
# 다음 마운트 시 원본이 스냅샷 시점으로 복구됨
mount /dev/vg_data/lv_app /app
```

---

## 6. 씬 프로비저닝 (Thin Provisioning)

씬 프로비저닝은 실제 사용량만큼만 물리 스토리지를 소비하고, 총 할당 용량이 물리 용량을 초과할 수 있다(오버프로비저닝).

```
물리 디스크: 100G
Thin Pool:   100G
  ├── thin_lv1: 50G 할당 (실제 사용 10G)
  ├── thin_lv2: 50G 할당 (실제 사용 5G)
  └── thin_lv3: 50G 할당 (실제 사용 3G)
  총 할당: 150G > 물리 100G ← 오버프로비저닝
  실제 사용: 18G
```

```bash
# Thin Pool 생성 (VG에서 80G 할당)
lvcreate -L 80G --thinpool tp_data vg_data

# Thin LV 생성 (풀 용량 초과 할당 가능)
lvcreate -V 50G --thin -n thin_lv1 vg_data/tp_data
lvcreate -V 50G --thin -n thin_lv2 vg_data/tp_data

# Thin Pool 사용률 모니터링
lvs -o +data_percent,metadata_percent vg_data
# Data% 가 80% 이상이면 경보 필요

# > **주의**: Thin Pool이 가득 차면 모든 Thin LV가 읽기전용으로 전환된다.
# 모니터링 없이 오버프로비저닝하면 서비스 장애로 이어진다.
```

---

## 7. AWS EBS와 LVM 실전 패턴

### 7.1 여러 EBS를 하나의 VG로 묶기

대용량 단일 볼륨이 필요하지만 AWS EBS 한도(16TB)를 초과하거나, I/O 성능 향상을 위해 스트라이핑이 필요할 때 사용한다.

```
AWS EC2 인스턴스
  ├── /dev/xvdb  (EBS gp3, 1TB)  ─┐
  ├── /dev/xvdc  (EBS gp3, 1TB)  ─┤→ vg_data → lv_data (2TB)
  └── /dev/xvdd  (EBS gp3, 1TB)  ─┘           lv_backup (1TB)
```

```bash
# 스트라이핑으로 I/O 성능 향상 (RAID-0 유사)
# -i: 스트라이프 수 (PV 수와 동일 권장)
# -I: 스트라이프 크기 (64KB~256KB, EBS는 256KB 권장)
lvcreate -L 2T -n lv_data -i 3 -I 256 vg_data

# 선형 배치 (기본값, 한 PV가 꽉 차면 다음 PV 사용)
lvcreate -L 2T -n lv_data vg_data
```

### 7.2 User Data로 초기 설정 자동화

```bash
#!/bin/bash
# EC2 User Data 스크립트: EBS 마운트 및 LVM 구성

# LVM 패키지 설치
yum install -y lvm2

# 디바이스 준비 대기
sleep 5

# PV/VG/LV 생성
pvcreate /dev/xvdb /dev/xvdc
vgcreate vg_data /dev/xvdb /dev/xvdc
lvcreate -l 100%FREE -n lv_app vg_data

# 파일시스템 생성 및 마운트
mkfs.xfs /dev/vg_data/lv_app
mkdir -p /app
mount /dev/vg_data/lv_app /app

# fstab 등록
echo '/dev/vg_data/lv_app /app xfs defaults 0 2' >> /etc/fstab
```

---

## 8. Ansible로 LVM 구성 자동화

```yaml
# playbooks/lvm_setup.yml
---
- name: LVM 볼륨 구성
  hosts: app_servers
  become: true
  vars:
    vg_name: vg_data
    lv_name: lv_app
    lv_size: "80%VG"         # VG 여유 공간의 80% 사용
    mount_point: /app
    fs_type: xfs

  tasks:
    - name: lvm2 패키지 설치
      package:
        name: lvm2
        state: present

    - name: PV 생성
      lvg:
        vg: "{{ vg_name }}"
        pvs:
          - /dev/xvdb
          - /dev/xvdc
        state: present

    - name: LV 생성
      lvol:
        vg: "{{ vg_name }}"
        lv: "{{ lv_name }}"
        size: "{{ lv_size }}"
        state: present

    - name: 파일시스템 생성
      filesystem:
        fstype: "{{ fs_type }}"
        dev: "/dev/{{ vg_name }}/{{ lv_name }}"

    - name: 마운트 포인트 생성
      file:
        path: "{{ mount_point }}"
        state: directory
        mode: '0755'

    - name: 볼륨 마운트 및 fstab 등록
      mount:
        path: "{{ mount_point }}"
        src: "/dev/{{ vg_name }}/{{ lv_name }}"
        fstype: "{{ fs_type }}"
        opts: defaults
        state: mounted

    - name: LVM 상태 확인
      command: lvs
      register: lvm_status
      changed_when: false

    - name: LVM 상태 출력
      debug:
        var: lvm_status.stdout_lines
```

---

## 9. LVM 메타데이터 백업 및 복구

LVM은 `/etc/lvm/backup/`에 VG 메타데이터를 자동으로 백업한다.

```bash
# 수동 메타데이터 백업
vgcfgbackup vg_data -f /root/vg_data_backup.cfg

# 메타데이터 손상 시 복구
vgcfgrestore vg_data -f /root/vg_data_backup.cfg

# VG가 사라진 경우 디스크에서 PV 스캔
pvscan                     # 모든 디스크에서 PV 검색
vgscan                     # VG 재검색
lvscan                     # LV 재검색

# 비활성 VG 활성화
vgchange -ay vg_data
```

---

## 10. 자주 하는 실수

| 실수 | 원인 | 올바른 방법 |
|------|------|-------------|
| `resize2fs` 후에도 용량이 늘지 않음 | `lvextend` 없이 `resize2fs`만 실행 | `lvextend` → `resize2fs` 순서 준수 |
| xfs 볼륨에 `resize2fs` 사용 | ext4 전용 명령어 혼동 | xfs는 `xfs_growfs` 사용 |
| 스냅샷 볼륨 크기 너무 작게 설정 | CoW 비용 과소평가 | 원본 LV 크기의 15~20% 이상 확보 |
| `lvremove` 전 umount 생략 | 마운트된 LV 삭제 시도 | `umount` → `lvremove` 순서 준수 |
| Thin Pool Data% 미모니터링 | 풀 가득 참 → LV 일괄 읽기전용 | CloudWatch 또는 알람으로 80% 임계값 설정 |
| PV를 파티션 없이 쓸 수 없다고 오해 | 습관적으로 파티션 생성 후 PV 지정 | 디스크 전체(`/dev/xvdb`)를 직접 PV로 사용 가능 |
| fstab에 `/dev/vg/lv` 경로 사용 | VG 이름 변경 시 부팅 실패 위험 | UUID 사용 권장 (`blkid`로 확인) |
| LV 축소 시 데이터 손실 | 파일시스템 축소 없이 LV 축소 | 파일시스템 축소 → LV 축소 순서 (xfs는 축소 불가) |
