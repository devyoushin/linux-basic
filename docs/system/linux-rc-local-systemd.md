
## 1. 개요
Linux 시스템 부팅 시 특정 스크립트나 바이너리를 자동으로 실행하기 위한 두 가지 주요 메커니즘인 `rc.local`과 `systemd`를 분석한다. 현대적인 클라우드 인프라 표준인 `systemd`를 중심으로 실무 적용 가능한 구성 방안과 관리 전략을 제시한다.

## 2. 설명

### 2.1 기술 비교: rc.local vs systemd
* **rc.local**: SysVinit 시대의 유물로, 부팅 프로세스의 마지막 단계에서 단순 스크립트를 실행한다. 프로세스 상태 감시, 의존성 제어, 병렬 실행이 불가능하다.
* **systemd**: 현대 Linux의 표준 Init 시스템이다. 유닛(Unit) 단위로 서비스를 관리하며 리소스 제한, 자동 재시작, 정교한 로그 수집(Journald) 기능을 제공한다.

### 2.2 실무 적용 코드 (Systemd Service Unit)
보안과 안정성을 고려한 표준 서비스 유닛 설정 예시이다.

**파일 경로: `/etc/systemd/system/backend-api.service`**
```ini
[Unit]
Description=Backend API Service for Production
# 네트워크가 준비된 후 실행되도록 보장
After=network-online.target
Wants=network-online.target

[Service]
# 보안: 루트 권한이 아닌 전용 서비스 계정 사용
User=deploy-user
Group=deploy-user
WorkingDirectory=/app/backend

# 실행 명령 및 환경 변수 설정
Environment=NODE_ENV=production
ExecStart=/usr/bin/node server.js

# 장애 대응: 프로세스 비정상 종료 시 5초 후 무한 재시작
Restart=always
RestartSec=5

# 비용 및 보안: 리소스 격리 및 제한
CPUQuota=50%
MemoryLimit=1G
# 임시 파일 시스템 격리
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### 2.3 모니터링 및 알람(Alerting) 전략
Prometheus의 node_exporter를 활용하여 서비스 다운타임을 감지하는 전략을 수립한다.

- Prometheus Alert Rule (alerts.yml)
```yaml
groups:
- name: service_alerts
  rules:
  - alert: CriticalServiceDown
    # 특정 서비스의 상태가 'active'가 아닐 경우 발생
    expr: node_systemd_unit_state{name="backend-api.service", state="active"} == 0
    for: 30s
    labels:
      severity: critical
    annotations:
      summary: "서비스 중단: {{ $labels.name }}"
      description: "인스턴스 {{ $labels.instance }}에서 backend-api가 다운되었습니다."
```

## 3. 트러블슈팅
### 3.1 rc.local 실행 실패
최신 배포판(Ubuntu 20.04+, RHEL 7+ 등)에서는 rc-local.service가 기본적으로 비활성화되어 있다.

- 원인: /etc/rc.local 파일이 존재하지 않거나 실행 권한이 없다.
- 해결: 파일 생성 후 `chmod +x /etc/rc.local`을 수행하고, `systemctl enable rc-local`을 통해 서비스를 명시적으로 활성화한다.

### 3.2 서비스 실행 후 즉시 종료 (Exit Code 203)
주로 실행 파일의 경로가 절대 경로가 아니거나 권한 설정 문제로 발생한다.

- 원인: ExecStart에 상대 경로 사용 또는 해당 계정에 실행 권한이 없다.
- 해결: 반드시 전체 경로(/usr/bin/...)를 기술하고, 설정된 User가 WorkingDirectory 및 실행 파일에 대한 읽기/실행 권한을 가졌는지 확인한다.

## 4. 참고자료
[Systemd.service Manual Page](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html?__goaway_challenge=meta-refresh&__goaway_id=233a33b08faebc6addf8c1d5d483a82f&__goaway_referer=https%3A%2F%2Fgemini.google.com%2F)\
[Prometheus Node Exporter Systemd Collector Guide](https://github.com/prometheus/node_exporter)

## TIP
- 설정 즉시 반영: `.service` 파일 수정 후에는 반드시 `systemctl daemon-reload`를 실행해야 변경 사항이 시스템에 등록된다.
- 로그 실시간 확인: `journalctl -u backend-api.service -f` 명령어로 서비스 로그를 모니터링한다.
- 의존성 검증: `systemd-analyze verify backend-api.service` 명령어로 문법 오류 및 종속성 문제를 사전에 검토한다.
