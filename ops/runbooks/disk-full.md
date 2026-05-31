# Disk Full Runbook

## 증상

파일시스템 사용률이 100%에 가깝거나 애플리케이션이 파일 쓰기에 실패합니다.

## 1. 사용률 확인

```bash
df -hT
df -hi
findmnt
```

## 2. 큰 디렉터리 확인

```bash
target=/
du -xh --max-depth=1 "$target" 2>/dev/null | sort -h | tail -20
```

## 3. 삭제된 파일을 잡고 있는 프로세스 확인

```bash
lsof +L1
```

## 4. 판단

- byte 사용률이 높으면 큰 파일과 로그 증가를 확인합니다.
- inode 사용률이 높으면 작은 파일이 많은 디렉터리를 찾습니다.
- 파일 삭제 후에도 공간이 안 돌아오면 deleted file을 잡은 프로세스를 재시작해야 할 수 있습니다.

## 관련 문서

- `docs/storage/linux-df-du.md`
- `docs/storage/linux-inode.md`
- `docs/storage/linux-large-dir-ops.md`
