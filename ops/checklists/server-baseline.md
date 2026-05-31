# 서버 초기 점검 체크리스트

## 시스템

- [ ] OS 버전과 커널 버전을 확인했다.
- [ ] 시간 동기화가 정상이다.
- [ ] CPU, 메모리, 디스크 용량을 확인했다.
- [ ] swap 설정을 확인했다.
- [ ] 실패한 systemd unit이 없다.

## 네트워크

- [ ] IP 주소와 routing table을 확인했다.
- [ ] DNS resolver 설정을 확인했다.
- [ ] 필요한 listening port만 열려 있다.
- [ ] 방화벽 정책을 확인했다.

## 보안

- [ ] SSH root login 정책을 확인했다.
- [ ] PasswordAuthentication 정책을 확인했다.
- [ ] sudo/wheel 권한 사용자를 확인했다.
- [ ] 불필요한 계정과 SUID 파일을 확인했다.

## 빠른 명령

```bash
bash ops/scripts/system-summary.sh
bash ops/scripts/network-summary.sh
bash ops/scripts/security-baseline-check.sh
```
