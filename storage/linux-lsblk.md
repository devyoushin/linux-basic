# 1. 개요

`lsblk` (List Block Devices)는 단순한 목록 확인 도구를 넘어, 현대적인 클라우드 환경(AWS NVMe 등)에서 스토리지 계층 구조를 파악하고, `/etc/fstab` 설정을 위한 고유 식별자(UUID)를 추출하는 핵심 유틸리티입니다. 본 문서에서는 `lsblk`의 상세 옵션과 실무 활용 케이스를 다룹니다.

# 2. 설명

### 2.1 블록 장치 계층 구조 이해

리눅스에서 스토리지는 물리 디스크(Disk) -> 파티션(Partition) -> LVM(선택사항) -> 파일시스템(Filesystem) 순으로 계층화됩니다. `lsblk`는 이 관계를 트리 구조로 시각화합니다.

### 2.2 실무 필수 옵션 및 커스텀 출력

단순 `lsblk`보다는 운영 환경에 맞는 특정 컬럼을 지정하여 사용하는 것이 효율적입니다.


```bash
# 1. 파일시스템 타입(FSTYPE)과 UUID, 마운트 지점 확인 (fstab 작업 시 필수)
lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT,UUID

# 2. 장치 모델명 및 고유 시리얼 번호 확인 (물리 서버 디스크 교체 시)
lsblk -o NAME,MODEL,SERIAL

# 3. JSON 형식 출력 (스크립트 및 자동화 도구 연동 시)
lsblk -J
```

### 2.3 IaC / Shell Script 활용 (Automation)

EBS 볼륨이 추가되었을 때, 자동으로 특정 장치명을 찾아 파일시스템을 생성하는 로직입니다.

```bash
#!/bin/bash
# NVMe 장치인지 확인하고 마운트되지 않은 디스크만 추출하는 로직
TARGET_DISK=$(lsblk -dnvo NAME,MOUNTPOINT | awk '$2 == "" {print "/dev/"$1}' | head -n 1)

if [ -z "$TARGET_DISK" ]; then
    echo "새로운 가용 디스크가 없습니다."
    exit 1
fi

echo "Target Disk: $TARGET_DISK"
# XFS 포맷 및 마운트 진행...
```

### 2.4 Terraform: EBS Volume 관리 및 Tagging


```hcl
resource "aws_ebs_volume" "app_data" {
  availability_zone = "ap-northeast-2a"
  size              = 50
  type              = "gp3"
  iops              = 3000
  throughput        = 125

  tags = {
    Name = "app-storage-01"
    Role = "DataPersistence"
  }
}
```

# 3. 트러블슈팅

### 3.1 디스크가 보이지 않을 때 (Rescan)

새로운 EBS를 연결했는데 `lsblk`에 나타나지 않는다면 커널에 재스캔 신호를 보내야 합니다.


```bash
# SCSI 버스 재스캔 (필요 시)
echo 1 > /sys/class/block/sdX/device/rescan
```

### 3.2 Partition Table Mismatch

`lsblk`에서는 용량이 늘어난 것으로 보이지만 `df -h`에서는 그대로인 경우, 파일시스템 확장(Resize)이 필요합니다.

- **XFS:** `xfs_growfs /mount/point`
- **EXT4:** `resize2fs /dev/device_name`

### 3.3 모니터링 전략 (Alerting)

- **장치 유실 감지:** `node_disk_info` 메트릭이 사라지거나 특정 `device`의 I/O 에러가 급증할 때 알람을 설정합니다.
- **성능 병목:** `lsblk`로 확인된 특정 디바이스의 `iowait`이 10%를 상회할 경우 gp3의 Throughput 상향을 검토해야 합니다.

# 4. 참고자료

- [Linux Manual Page: lsblk(8)](https://man7.org/linux/man-pages/man8/lsblk.8.html)
- [AWS Guide: Making an Amazon EBS volume available for use on Linux](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-using-volumes.html)

# TIP

- **알파벳 'f'의 마법:** `lsblk -f`는 엔지니어가 가장 많이 사용하는 단축 옵션입니다. 모든 파일시스템 정보와 마운트 상태를 한 번에 보여줍니다.
- **RO (Read-Only) 확인:** `lsblk` 출력 항목 중 `RO` 컬럼이 `1`이라면 해당 디스크는 읽기 전용으로 마운트된 것입니다. 파일시스템 손상(Corruption) 시 커널이 보호를 위해 RO로 전환할 수 있으니 주의 깊게 살펴야 합니다.
- **용량 단위:** `lsblk --bytes`를 사용하면 정확한 바이트 단위 용량을 알 수 있어 정밀한 파티셔닝 계산 시 유용합니다.
