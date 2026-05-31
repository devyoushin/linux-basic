# 배포 전 점검 체크리스트

## 리소스

- [ ] CPU load average가 평소 범위 안에 있다.
- [ ] MemAvailable과 swap 사용량이 정상이다.
- [ ] 대상 파일시스템 사용률과 inode 사용률이 안전하다.
- [ ] 배포 대상 서비스의 현재 상태를 확인했다.

## 변경 영향

- [ ] 변경되는 systemd unit, config, binary 경로를 확인했다.
- [ ] 재시작이 필요한 서비스와 영향 범위를 확인했다.
- [ ] 롤백 파일 또는 이전 버전을 확보했다.
- [ ] 로그 확인 명령을 준비했다.

## 빠른 명령

```bash
systemctl status <service>
journalctl -u <service> --since "30 minutes ago" --no-pager
df -hT
df -hi
free -h
```
