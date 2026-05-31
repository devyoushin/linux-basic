# Linux Ops

Linux 운영 스크립트와 실습 자산을 두는 공간입니다.

| 폴더 | 내용 |
|------|------|
| `scripts/` | 반복 실행 가능한 진단/점검 스크립트 |
| `labs/` | 재현 가능한 실습 파일과 절차 |
| `runbooks/` | 장애 상황별 대응 절차 |
| `checklists/` | 서버 초기 점검, 배포 전 점검, 보안 점검 |
| `configs/` | sysctl, systemd, sshd, limits 설정 예시 |
| `outputs/` | 실습 결과와 명령 출력 샘플 |

문서와 설명은 `../docs/README.md`를 참고합니다.

## 빠른 실행

```bash
bash ops/scripts/system-summary.sh
bash ops/scripts/memory-check.sh
bash ops/scripts/disk-check.sh
bash ops/scripts/network-summary.sh
bash ops/scripts/systemd-failed-units.sh
```

스크립트는 기본적으로 읽기 전용 진단을 목적으로 합니다. 운영 서버에서 실행하기 전에는 내용을 먼저 확인합니다.
