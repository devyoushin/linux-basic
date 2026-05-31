# linux-systemctl.md — systemd 서비스 관리

## 1. 개요

systemd는 현대 Linux 배포판의 표준 init 시스템이자 서비스 관리자다. SRE/DevOps 관점에서 서비스 기동·중단·재시작·상태 확인·장애 추적은 모두 `systemctl`을 통해 이루어진다. 컨테이너 환경에서도 호스트 데몬 관리, 노드 부팅 후 서비스 자동 시작 설정은 여전히 systemctl이 핵심이다.

---

## 2. 설명

### 2.1 기본 서비스 제어

```bash
# 서비스 시작 / 중지 / 재시작 / 재로드
systemctl start nginx
systemctl stop nginx
systemctl restart nginx
systemctl reload nginx          # 프로세스 유지 + 설정 재로드 (무중단)

# 부팅 시 자동 시작 설정 / 해제
systemctl enable nginx
systemctl disable nginx
systemctl enable --now nginx    # 활성화 + 즉시 시작 (원샷)
systemctl disable --now nginx   # 비활성화 + 즉시 중지

# 상태 확인
systemctl status nginx          # 최근 로그 포함 상태 출력
systemctl is-active nginx       # active / inactive (스크립트용)
systemctl is-enabled nginx      # enabled / disabled (스크립트용)
systemctl is-failed nginx       # failed 여부 확인
```

### 2.2 시스템 전체 조회

```bash
# 실행 중인 서비스 목록
systemctl list-units --type=service --state=running

# 실패한 서비스 목록 (인시던트 초동 대응 필수)
systemctl list-units --type=service --state=failed

# 모든 유닛 상태 한 눈에 보기
systemctl list-units --all

# 의존성 트리 출력 (부팅 순서 파악)
systemctl list-dependencies nginx
systemctl list-dependencies --reverse nginx   # 역방향: 누가 nginx에 의존하는지
```

### 2.3 서비스 유닛 파일 관리

```bash
# 유닛 파일 위치 확인
systemctl cat nginx             # 실제 로드된 유닛 파일 출력

# 유닛 파일 직접 편집 (재정의 디렉토리 /etc/systemd/system/)
systemctl edit nginx            # drop-in override 파일 생성 (원본 보존)
systemctl edit --full nginx     # 전체 유닛 파일 편집

# 편집 후 반드시 데몬 재로드
systemctl daemon-reload

# 유닛 파일 검증
systemd-analyze verify /etc/systemd/system/myapp.service
```

### 2.4 사용자 정의 서비스 유닛 작성

애플리케이션을 systemd 서비스로 등록하는 것은 SRE의 기본 업무다.

```ini
# /etc/systemd/system/myapp.service
[Unit]
Description=My Application Service
After=network-online.target      # 네트워크 준비 후 시작
Wants=network-online.target
After=postgresql.service         # DB 의존성

[Service]
Type=simple                      # forking / oneshot / notify / idle
User=myapp                       # 전용 계정으로 실행 (root 금지)
Group=myapp
WorkingDirectory=/opt/myapp
EnvironmentFile=/etc/myapp/env   # 환경변수 파일 분리 (비밀값 보호)
ExecStart=/opt/myapp/bin/server --config /etc/myapp/config.yaml
ExecReload=/bin/kill -HUP $MAINPID   # reload 시 SIGHUP 전송

# 재시작 정책
Restart=on-failure               # 비정상 종료 시만 재시작
RestartSec=5s                    # 재시작 전 대기
StartLimitIntervalSec=60s        # 60초 내
StartLimitBurst=3                # 3회 초과 재시작 시 포기

# 리소스 제한 (cgroup 기반)
LimitNOFILE=65536                # fd 최대값
MemoryMax=2G                     # 메모리 상한
CPUQuota=200%                    # CPU 2코어 상당

# 보안 강화
NoNewPrivileges=yes              # setuid/setgid 차단
PrivateTmp=yes                   # /tmp 격리
ProtectSystem=strict             # / 읽기 전용
ReadWritePaths=/var/lib/myapp    # 쓰기 허용 경로만 명시

# 종료 타임아웃
TimeoutStopSec=30s               # 30초 후 SIGKILL

[Install]
WantedBy=multi-user.target       # 런레벨 3 상당에서 자동 시작
```

```bash
# 유닛 등록 및 활성화
systemctl daemon-reload
systemctl enable --now myapp.service
```

### 2.5 서비스 장애 디버깅 플로우

```bash
# 1) 실패 목록 확인
systemctl list-units --state=failed

# 2) 상태 및 최근 로그 확인
systemctl status myapp.service -l    # -l: 로그 잘림 방지

# 3) journald에서 전체 로그 조회
journalctl -u myapp.service -n 100   # 최근 100줄
journalctl -u myapp.service --since "10 minutes ago"
journalctl -u myapp.service -f       # 실시간 tail

# 4) 실패 이유 코드 확인
systemctl show myapp.service --property=ExecMainStatus
systemctl show myapp.service --property=Result

# 5) 실패 카운터 초기화 후 재시도
systemctl reset-failed myapp.service
systemctl start myapp.service
```

### 2.6 부팅 성능 분석 (SRE: 노드 시작 시간 최적화)

```bash
# 부팅 전체 시간 요약
systemd-analyze

# 각 유닛별 기동 시간 정렬
systemd-analyze blame

# SVG 크리티컬 체인 시각화
systemd-analyze plot > boot.svg

# 부팅 병목 크리티컬 체인 텍스트 출력
systemd-analyze critical-chain
```

### 2.7 서비스 격리 및 임시 실행

```bash
# 임시로 특정 환경으로 명령 실행 (테스트용)
systemd-run --unit=debug-run --pty bash

# 리소스 제한 적용해서 일회성 실행
systemd-run --scope -p MemoryMax=500M --uid=nobody /bin/my-job

# 특정 서비스와 동일한 cgroup/환경에서 명령 실행
nsenter --target $(systemctl show --property=MainPID --value myapp) --mount --uts --ipc --net
```

### 2.8 Terraform / Ansible 연계

```yaml
# Ansible: 서비스 배포 후 활성화 패턴
- name: Deploy myapp systemd unit
  template:
    src: myapp.service.j2
    dest: /etc/systemd/system/myapp.service
    mode: '0644'

- name: Reload systemd daemon
  systemd:
    daemon_reload: yes

- name: Enable and start myapp
  systemd:
    name: myapp
    enabled: yes
    state: started
```

```hcl
# Terraform: user_data로 서비스 자동 설치
resource "aws_instance" "app" {
  user_data = <<-EOF
    #!/bin/bash
    # 유닛 파일 복사 후 활성화
    cp /tmp/myapp.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now myapp
  EOF
}
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|------|------------|
| 유닛 파일 편집 후 `daemon-reload` 생략 | 수정 후 반드시 `systemctl daemon-reload` 실행 |
| `enable` 후 서비스가 즉시 시작된다고 착각 | `enable`은 부팅 자동시작만 설정. 즉시 시작하려면 `enable --now` |
| `restart` vs `reload` 혼용 | reload는 프로세스 유지+설정 갱신(무중단). 코드 변경 시엔 restart |
| `root`로 서비스 실행 | `User=`로 전용 계정 지정. 침해 시 피해 최소화 |
| 재시작 루프 방치 | `StartLimitBurst` 설정 + `systemctl reset-failed` 후 원인 분석 |
| 환경변수를 유닛 파일에 직접 하드코딩 | `EnvironmentFile=`로 외부 파일 분리, 비밀값은 Vault/SSM 연계 |
| `TimeoutStopSec` 미설정으로 종료 지연 | 그레이스풀 셧다운 시간 명시, 이후 SIGKILL 보장 |
| `After=` 없이 DB 의존 서비스 기동 | `After=postgresql.service` + `Requires=` 또는 `Wants=` 명시 |
