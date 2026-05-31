# systemd Service Failed Runbook

## 증상

서비스가 failed 상태이거나 재시작을 반복합니다.

## 1. 상태 확인

```bash
service=<service>
systemctl status "$service" --no-pager
systemctl show "$service" -p ExecMainStatus -p ExecMainCode -p NRestarts
```

## 2. 로그 확인

```bash
journalctl -u "$service" --since "1 hour ago" --no-pager
```

## 3. unit 설정 확인

```bash
systemctl cat "$service"
systemd-analyze verify /etc/systemd/system/"$service"
```

## 4. 판단

- exit code가 설정 오류인지 애플리케이션 오류인지 분리합니다.
- `Restart=` 정책 때문에 장애가 가려지는지 확인합니다.
- 환경 변수, WorkingDirectory, 권한, 파일 경로를 확인합니다.

## 관련 문서

- `docs/system/linux-systemctl.md`
- `docs/system/linux-rc-local-systemd.md`
- `docs/system/linux-journalctl.md`
