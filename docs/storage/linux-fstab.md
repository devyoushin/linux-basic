## 1. 개요
`/etc/fstab` (File System Table)은 리눅스 시스템 부팅 시 파일 시스템을 자동으로 마운트하기 위한 설정 파일이다.
클라우드 환경(AWS 등)에서 추가 EBS 볼륨이나 EFS를 연결할 때 필수적으로 다루게 되며, 설정 오류 시 **부팅 실패(Boot Failure)**로 이어질 수 있어 실무에서 매우 신중하게 다뤄야 하는 영역이다.

## 2. 설명
### 2.1. fstab 구성 요소
각 라인은 6개의 필드로 구성된다:
`[Device] [Mount Point] [File System Type] [Options] [Dump] [Pass]`

### 2.2. 실무 코드 (Infrastructure as Code)
### A. Terraform: EBS 볼륨 마운트 자동화 (User Data)
EC2 인스턴스 생성 시 자동으로 EBS를 포맷하고 /etc/fstab에 등록하는 스크립트 예시입니다. AWS에서는 디바이스 이름이 변경될 수 있으므로 UUID 사용이 필수이다.
```tf
resource "aws_instance" "app_server" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "t3.medium"

  user_data = <<-EOF
              #!/bin/bash
              DEVICE_NAME="/dev/xvdf"
              MOUNT_POINT="/data"
              
              # 파일 시스템 확인 및 생성 (없을 경우에만)
              if [ -z "$(lsblk -f | grep $DEVICE_NAME | awk '{print $4}')" ]; then
                mkfs -t xfs $DEVICE_NAME
              fi

              mkdir -p $MOUNT_POINT
              
              # UUID 추출
              UUID=$(blkid -s UUID -o value $DEVICE_NAME)
              
              # /etc/fstab 등록 (nofail 옵션 필수)
              echo "UUID=$UUID $MOUNT_POINT xfs defaults,nofail 0 2" >> /etc/fstab
              mount -a
              EOF
}
```

### B. YAML (Ansible): fstab 관리
```yaml
- name: Mount EBS Volume
  ansible.posix.mount:
    path: /data
    src: UUID=1234-5678-90AB
    fstype: xfs
    opts: defaults,nofail
    state: mounted
```

### 2.3. 보안 및 비용 Best Practice
- Security: nosuid, nodev, noexec 옵션을 활용하여 데이터 전용 파티션에서의 바이너리 실행을 차단한다.
    - 예: `UUID=... /data xfs defaults,nosuid,nodev,noexec 0 2`
- Cost: 불필요한 EBS Snapshot 비용을 줄이기 위해, 임시 데이터 성격의 마운트 포인트(예: /tmp, /scratch)는 별도의 EBS보다는 인스턴스 스토어(Ephemeral Storage) 사용을 검토하세요.

## 3. 트러블슈팅
### 3.1. 문제: 부팅 시 'Emergency Mode' 진입
- 원인: `/etc/fstab`에 등록된 장치가 존재하지 않거나 `UUID`가 틀렸을 경우 리눅스는 부팅을 멈춘다.
- 해결:
1. nofail 옵션을 사용했다면 부팅은 성공함.
2. 부팅 불가 시, AWS의 경우 EC2 Serial Console을 사용하거나, 인스턴스 중지 후 볼륨을 다른 인스턴스에 붙여 `/etc/fstab`을 수정.

### 3.2. 모니터링 및 알람 전략
- Mount Point Check: Prometheus의 node_exporter를 사용하여 마운트 상태를 감시.
- Alerting Rule (Prometheus):
```yaml
groups:
- name: disk_alerts
  rules:
  - alert: MountPointMissing
    expr: node_filesystem_readonly{mountpoint="/data"} == 1 or absent(node_filesystem_size_bytes{mountpoint="/data"})
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Mount point /data is missing or Read-Only"
```

## 4. 참고자료
- [AWS Documentation: Device names on Linux instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/device_naming.html)
- [Linux man-pages: fstab(5)](https://man7.org/linux/man-pages/man5/fstab.5.html)

## TIP
- 검증 필수: `/etc/fstab` 수정 후 반드시 `sudo mount -a` 명령어를 실행. 여기서 에러가 나면 재부팅 시 시스템이 올라오지 않을 확률이 100%이다.
- EFS 마운트: AWS EFS를 마운트할 때는 `amazon-efs-utils` 패키지를 설치하고 `_netdev` 옵션을 반드시 포함해야 네트워크가 준비된 후 마운트를 시도.
    - 예: `fs-xxxxxx:/ /mnt/efs efs defaults,_netdev 0 0`
