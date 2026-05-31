# Linux 코드 작성 규칙

이 저장소의 bash 명령어, 스크립트, 설정 파일 작성 규칙입니다.

---

## 1. Bash 명령어 규칙

### 기본 원칙
- 모든 명령어에 한국어 `#` 주석 추가
- 긴 명령어는 `\` 로 줄 바꿈
- 변수: `${VAR}` 형식으로 중괄호 포함

### 에러 핸들링 패턴
```bash
#!/bin/bash
set -euo pipefail  # 에러 시 즉시 종료

TARGET_DIR="${1:?'대상 디렉토리를 지정해야 합니다'}"
```

### 플레이스홀더 표기법

| 타입 | 형식 |
|------|------|
| 디바이스 | `<DEVICE>` |
| 마운트 포인트 | `<MOUNT_POINT>` |
| IP 주소 | `<IP_ADDR>` |
| 서버명 | `<HOSTNAME>` |

## 2. systemd Unit 파일 규칙

```ini
[Unit]
Description=<서비스 설명>
After=network.target

[Service]
Type=simple
User=<USER>                # root 사용 금지 (불가피한 경우 명시)
ExecStart=<COMMAND>
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## 3. 위험 명령어 경고 필수 항목

다음 명령어 사용 시 반드시 `> **주의**` 블록 추가:
- `rm -rf` — 되돌릴 수 없는 삭제
- `dd if=` — 디스크 덮어쓰기
- `mkfs` — 파일시스템 포맷 (데이터 소실)
- `fdisk` / `parted` — 파티션 변경

## 4. Terraform 예제 규칙

```hcl
# 버전: hashicorp/aws ~> 5.0 기준
resource "aws_instance" "example" {
  ami           = "<AMI_ID>"
  instance_type = "t3.micro"

  tags = {
    Name        = "<NAME>"
    Environment = "<ENVIRONMENT>"
    ManagedBy   = "terraform"
  }
}
```
