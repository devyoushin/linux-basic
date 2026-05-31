## 1. 개요

`journalctl`은 systemd의 로그 수집 데몬인 `journald`가 관리하는 이진(binary) 로그 저장소를 조회하는 도구다.
기존 `/var/log/syslog`, `/var/log/messages`를 대체하며, 서비스 단위로 필터링하거나 부팅 시점별로 로그를 분리하는 등 실무 장애 대응 속도를 크게 높여준다.

> 관련 문서: `linux-rc-local-systemd.md` (systemd 서비스 유닛 작성)

## 2. 설명

### 2.1 journald 로그 저장 방식

| 설정 | 저장 경로 | 재부팅 후 |
|---|---|---|
| `Storage=volatile` | `/run/log/journal/` (RAM) | 사라짐 |
| `Storage=persistent` | `/var/log/journal/` (디스크) | 유지됨 |
| `Storage=auto` (기본값) | `/var/log/journal/` 디렉토리 존재 시 persistent | 조건부 |

```bash
# 영구 저장 활성화 (기본값이 volatile인 배포판 대상)
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald
```

### 2.2 핵심 조회 명령어

```bash
# 전체 로그 (최신순 역방향 출력)
journalctl -r

# 실시간 로그 스트리밍 (tail -f 대응)
journalctl -f

# 특정 서비스 로그
journalctl -u nginx.service
journalctl -u nginx.service -f  # 실시간

# 최근 N줄만 출력
journalctl -u nginx.service -n 50

# 특정 우선순위 이상만 출력 (0=emerg ~ 7=debug)
journalctl -p err        # error 이상
journalctl -p warning    # warning 이상

# 현재 부팅 이후 로그만
journalctl -b

# 이전 부팅 로그 (0=현재, -1=직전, -2=그 전)
journalctl -b -1

# 시간 범위 지정
journalctl --since "2024-01-15 10:00:00" --until "2024-01-15 11:00:00"
journalctl --since "1 hour ago"
journalctl --since today
```

### 2.3 장애 대응 실전 패턴

#### 서비스 재시작 직전/직후 로그 비교

```bash
# 서비스가 왜 죽었는지 마지막 기동 실패 로그 확인
journalctl -u my-app.service -b --no-pager | grep -E "ERROR|FATAL|killed|failed"

# 서비스 상태 + 최근 로그 한 번에 확인
systemctl status my-app.service

# 특정 PID가 남긴 로그 추적
journalctl _PID=1234

# 커널 메시지만 (OOM killer, 디스크 에러 등)
journalctl -k
journalctl -k -b -1  # 직전 부팅의 커널 로그 (OOM으로 강제종료 된 경우 확인)
```

#### OOM(Out of Memory) 사건 추적

```bash
# OOM killer 발동 이력 확인
journalctl -k | grep -i "oom\|killed process\|out of memory"

# 샘플 출력:
# Jan 15 03:21:44 server kernel: Out of memory: Kill process 4521 (java) score 892 or sacrifice child
# Jan 15 03:21:44 server kernel: Killed process 4521 (java) total-vm:4096000kB, anon-rss:3800000kB
```

### 2.4 로그 용량 관리

```bash
# 현재 journal 디스크 사용량 확인
journalctl --disk-usage

# 오래된 로그 정리
journalctl --vacuum-time=30d    # 30일 이전 로그 삭제
journalctl --vacuum-size=500M   # 총 500MB 초과 로그 삭제
journalctl --vacuum-files=5     # 최근 5개 파일만 유지
```

#### `/etc/systemd/journald.conf` 영구 설정

```ini
[Journal]
# 디스크에 영구 저장
Storage=persistent

# journal 최대 크기 제한
SystemMaxUse=1G
SystemKeepFree=200M

# 단일 파일 최대 크기
SystemMaxFileSize=100M

# 보관 기간 제한
MaxRetentionSec=30day

# 로그 압축 여부
Compress=yes
```

```bash
# 설정 변경 후 적용
systemctl restart systemd-journald
```

### 2.5 Terraform + CloudWatch로 journal 로그 수집

AWS 환경에서 EC2 인스턴스의 journal 로그를 CloudWatch Logs로 전송하는 패턴이다.

```hcl
resource "aws_instance" "app" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "t3.medium"
  iam_instance_profile = aws_iam_instance_profile.cloudwatch.name

  user_data = <<-EOF
    #!/bin/bash
    # CloudWatch Agent 설치 및 journal 연동
    yum install -y amazon-cloudwatch-agent

    cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CONFIG'
    {
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/var/log/journal/**",
                "log_group_name": "/ec2/${instance_id}/journal",
                "log_stream_name": "{instance_id}",
                "timezone": "UTC"
              }
            ]
          }
        }
      }
    }
    CONFIG

    systemctl enable amazon-cloudwatch-agent
    systemctl start amazon-cloudwatch-agent
  EOF
}
```

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `journalctl` 출력이 너무 많아 터미널 멈춤 | `--no-pager` 또는 `\| less` 사용 |
| `/var/log/journal` 없어서 재부팅 후 로그 사라짐 | `Storage=persistent` 설정 및 디렉토리 생성 |
| journal 용량이 디스크를 다 차지함 | `journald.conf`에 `SystemMaxUse` 제한 설정 |
| 이전 부팅 크래시 원인 파악 불가 | `journalctl -b -1 -k` 로 직전 부팅 커널 로그 확인 |
