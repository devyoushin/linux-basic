# OverlayFS와 컨테이너 레이어 스토리지

## 1. 개요

OverlayFS는 여러 디렉토리를 하나로 겹쳐 보이게 하는 리눅스 유니온 마운트 파일시스템이다. Docker가 이미지 레이어를 효율적으로 관리하기 위해 채택한 기본 스토리지 드라이버(overlay2)의 근간이다. 이미지 레이어는 읽기전용으로 공유하고, 컨테이너마다 변경 사항만 별도 레이어에 기록하는 구조로, 동일 이미지에서 수백 개의 컨테이너를 실행해도 디스크를 효율적으로 사용할 수 있다.

---

## 2. OverlayFS 동작 원리

### 2.1 4개의 디렉토리

```
OverlayFS 마운트 구조:

lower/    (읽기전용, 여러 개 가능)
  ├── etc/
  │   └── nginx.conf     ← 이미지 레이어 (변경 불가)
  └── usr/bin/nginx

upper/    (읽기쓰기, 컨테이너별 고유)
  └── etc/
      └── nginx.conf     ← lower의 파일을 수정하면 여기에 복사됨(CoW)

work/     (커널 내부 작업용, 비어 있어야 함)

merged/   (마운트 포인트, 컨테이너가 실제 보는 뷰)
  ├── etc/
  │   └── nginx.conf     ← upper에 있으면 upper 버전 표시
  └── usr/bin/nginx      ← lower에서 가져옴

마운트 명령:
mount -t overlay overlay \
  -o lowerdir=lower,upperdir=upper,workdir=work \
  merged/
```

### 2.2 Copy-on-Write (CoW) 동작

```
파일 읽기 (수정 없음):
  merged/usr/bin/nginx 읽기
    → upper에 없음 → lower에서 직접 읽기
    → lower 파일 변경 없음

파일 수정 (CoW 발동):
  merged/etc/nginx.conf 수정
    → upper에 없음 → lower에서 upper로 전체 파일 복사 (copy-up)
    → upper/etc/nginx.conf 수정
    → 이후 reads: upper 버전 반환

파일 삭제:
  merged/etc/old.conf 삭제
    → upper에 "whiteout" 파일 생성: upper/etc/.wh.old.conf
    → merged에서 해당 파일이 보이지 않게 됨
    → lower의 파일은 실제로 삭제되지 않음
```

---

## 3. Docker overlay2 스토리지 드라이버

### 3.1 이미지 레이어와 OverlayFS 매핑

```
Docker 이미지: nginx:latest
  Layer 1: FROM debian:bullseye     (베이스 OS)
  Layer 2: RUN apt-get install ...  (nginx 설치)
  Layer 3: COPY nginx.conf ...      (설정 파일)
  Layer 4: CMD ["nginx", "-g", ...] (실행 명령)

/var/lib/docker/overlay2/
  ├── <layer1-hash>/
  │   └── diff/   ← lower[0]: debian 파일시스템
  ├── <layer2-hash>/
  │   └── diff/   ← lower[1]: nginx 바이너리
  ├── <layer3-hash>/
  │   └── diff/   ← lower[2]: nginx.conf
  └── <container-hash>/
      ├── diff/   ← upper: 컨테이너 변경사항
      ├── work/   ← workdir
      └── merged/ ← 컨테이너가 보는 루트 파일시스템

OverlayFS 마운트:
  lowerdir=<layer3>/diff:<layer2>/diff:<layer1>/diff
  upperdir=<container>/diff
  workdir=<container>/work
  merged=<container>/merged
```

```bash
# 실행 중인 컨테이너의 overlay2 마운트 확인
docker inspect mycontainer | python3 -m json.tool | grep -A5 GraphDriver
# "GraphDriver": {
#   "Data": {
#     "LowerDir": "/var/lib/docker/overlay2/abc123/diff:...",
#     "MergedDir": "/var/lib/docker/overlay2/xyz789/merged",
#     "UpperDir": "/var/lib/docker/overlay2/xyz789/diff",
#     "WorkDir": "/var/lib/docker/overlay2/xyz789/work"
#   },
#   "Name": "overlay2"
# }

# 실제 마운트 정보
cat /proc/mounts | grep overlay
# overlay /var/lib/docker/overlay2/xyz789/merged overlay
#   rw,relatime,lowerdir=...,upperdir=...,workdir=... 0 0
```

### 3.2 레이어 크기 및 디스크 사용량 분석

```bash
# 전체 Docker 스토리지 사용량 요약
docker system df
# TYPE            TOTAL   ACTIVE  SIZE      RECLAIMABLE
# Images          15      5       8.234GB   4.123GB (50%)
# Containers      8       3       234.5MB   12.3MB
# Local Volumes   3       2       1.234GB   512MB
# Build Cache     0       0       0B        0B

# 이미지별 레이어 크기 확인
docker history nginx:latest
# IMAGE         CREATED    CREATED BY                   SIZE
# a1b2c3d4e5f6  2 days ago /bin/sh -c #(nop) CMD [...]  0B
# b2c3d4e5f6a7  2 days ago /bin/sh -c COPY nginx.conf   1.2kB
# c3d4e5f6a7b8  2 days ago /bin/sh -c apt-get install   52.3MB
# d4e5f6a7b8c9  2 weeks ago /bin/sh -c #(nop) FROM ...  80.4MB

# 컨테이너별 디스크 사용량 (SIZE: upper만, VIRTUAL: lower 포함 전체)
docker ps -s
# CONTAINER ID  IMAGE   ...  SIZE             VIRTUAL SIZE
# abc123def456  nginx   ...  2.3kB (unique)   133MB (shared)

# overlay2 디렉토리 직접 확인
ls -lh /var/lib/docker/overlay2/ | head -20
du -sh /var/lib/docker/overlay2/         # 전체 사용량
```

---

## 4. OverlayFS 성능 특성

### 4.1 메타데이터 heavy 작업이 느린 이유

```
copy-up 비용:
  작은 파일(1KB) 수정 → 전체 파일이 lower에서 upper로 복사
  큰 파일(100MB) 첫 수정 → 100MB 전체 복사 후 수정
  → 처음 수정 시 latency spike 발생

디렉토리 탐색 비용:
  ls /merged/big_directory
    → 모든 lower 레이어를 순차 탐색 (레이어 수에 비례)
    → 레이어가 많을수록(예: 50개) 탐색 비용 증가

rename 제한:
  lower에 있는 파일 rename
    → copy-up + 삭제 whiteout 생성 → 비용이 큼
    → DB (SQLite, LevelDB) 파일에 직접 쓰는 패턴에 불리
```

```bash
# 레이어 수 확인 (많을수록 성능 저하)
docker history myimage | wc -l

# 레이어를 최소화한 Dockerfile 최적화
# 나쁜 예: 레이어 4개
FROM ubuntu
RUN apt-get update
RUN apt-get install -y nginx
RUN apt-get clean

# 좋은 예: 레이어 2개 (RUN을 하나로 합침)
FROM ubuntu
RUN apt-get update && \
    apt-get install -y nginx && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
```

### 4.2 성능이 중요한 데이터는 volume으로 분리

```yaml
# docker-compose.yml
services:
  db:
    image: postgres:15
    volumes:
      # 데이터는 호스트 volume 또는 named volume에 저장
      # overlay2 상에 DB 파일을 두지 않음 (copy-up, rename 비용)
      - pgdata:/var/lib/postgresql/data
    tmpfs:
      - /tmp                    # 임시 파일은 tmpfs로 (메모리 기반, 빠름)

volumes:
  pgdata:
    driver: local
```

---

## 5. 트러블슈팅: "device or resource busy" 오류

### 5.1 원인 분석

```bash
# 컨테이너 삭제 시 오류 발생
docker rm -f mycontainer
# Error response from daemon: driver "overlay2" failed to remove root filesystem
# for ...: remove .../merged: device or resource busy

# 원인 1: merged 디렉토리가 다른 프로세스에 의해 바인드 마운트됨
# 원인 2: 컨테이너 내 파일시스템이 다른 네임스페이스에서 참조 중
# 원인 3: 불완전한 컨테이너 종료로 마운트 잔여

# 진단: merged 디렉토리를 사용 중인 프로세스 찾기
CONTAINER_ID="abc123def456"
MERGED_DIR=$(docker inspect $CONTAINER_ID | grep MergedDir | awk -F'"' '{print $4}')

# 해당 디렉토리를 사용 중인 프로세스
fuser -m "$MERGED_DIR" 2>/dev/null
lsof | grep "$MERGED_DIR"

# 해결: 마운트 강제 해제
umount -l "$MERGED_DIR"     # lazy umount (-l: 참조가 0이 되면 해제)
docker rm mycontainer
```

### 5.2 overlay2 디렉토리 정리

```bash
# 사용하지 않는 레이어 정리 (이미지/컨테이너 삭제 후 남은 레이어)
docker system prune -f          # 정지된 컨테이너, 미사용 이미지 정리
docker system prune -a -f       # 실행 중이 아닌 모든 이미지 정리

# > **주의**: `docker system prune -a`는 현재 실행 중이 아닌 모든 이미지를 삭제한다.
# 재시작 시 이미지를 다시 pull해야 하므로 프로덕션에서는 주의해서 사용한다.

# overlay2 레이어 vs Docker 관리 레이어 불일치 (고아 레이어) 확인
# Docker가 알고 있는 레이어
docker images -q | xargs docker inspect --format='{{.GraphDriver.Data.LowerDir}}' 2>/dev/null | tr ':' '\n' | sed 's|/diff||' | sort -u > /tmp/docker_layers.txt

# 실제 overlay2 디렉토리
ls /var/lib/docker/overlay2/ | sort > /tmp/fs_layers.txt

# 차이 확인 (Docker가 모르는 디렉토리 = 고아 레이어)
diff /tmp/docker_layers.txt /tmp/fs_layers.txt
```

---

## 6. 스토리지 드라이버 비교

```
┌──────────────┬──────────────┬──────────────┬──────────────┐
│ 드라이버      │ 커널 요구사항 │ 성능          │ 안정성       │
├──────────────┼──────────────┼──────────────┼──────────────┤
│ overlay2     │ 4.0+         │ 높음          │ 높음 (권장)  │
│ aufs         │ 별도 패치     │ 중간          │ 낮음 (레거시)│
│ devicemapper │ 모든 버전     │ loop: 낮음    │ direct-lvm  │
│              │              │ direct: 중간  │ 권장하지 않음│
│ btrfs        │ 지원 커널     │ 중간          │ 중간         │
│ zfs          │ 별도 설치     │ 높음          │ 높음         │
└──────────────┴──────────────┴──────────────┴──────────────┘
```

```bash
# 현재 스토리지 드라이버 확인
docker info | grep "Storage Driver"
# Storage Driver: overlay2

# overlay2로 변경 (/etc/docker/daemon.json)
cat > /etc/docker/daemon.json <<'EOF'
{
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.size=20G"          # 컨테이너당 최대 크기 제한
  ]
}
EOF
systemctl restart docker
```

---

## 7. Kubernetes에서 OverlayFS

### 7.1 노드별 컨테이너 레이어 확인

```bash
# kubelet이 사용하는 이미지 스토리지 확인
crictl images                   # containerd 사용 시
crictl ps                       # 실행 중인 컨테이너

# 컨테이너 루트 파일시스템 경로 확인
crictl inspect <container-id> | grep rootfs

# 노드 디스크 압박 시 이미지 GC 트리거 (kubelet이 자동으로 수행)
# 설정: /var/lib/kubelet/config.yaml
# imageGCHighThresholdPercent: 85  # 85% 이상이면 GC 시작
# imageGCLowThresholdPercent: 80   # 80% 미만으로 줄임
```

### 7.2 Ephemeral Storage 제한

```yaml
# Pod spec에서 컨테이너 레이어 크기 제한
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: myapp
    image: myapp:latest
    resources:
      requests:
        ephemeral-storage: "1Gi"    # overlay2 upper 레이어 포함
      limits:
        ephemeral-storage: "5Gi"    # 초과 시 Pod eviction
```

---

## 8. 자주 하는 실수

| 실수 | 원인 | 올바른 방법 |
|------|------|-------------|
| DB 데이터를 컨테이너 레이어에 저장 | volume 미사용 | Named volume 또는 hostPath로 overlay2 우회 |
| Dockerfile에서 RUN을 여러 줄로 분리 | 레이어 수 증가 → 성능 저하 | `&&`로 연결하여 레이어 최소화 |
| `docker system prune -a` 무분별 사용 | 실행 중 컨테이너의 이미지도 삭제 위험 | 실행 중인 이미지 먼저 확인 후 실행 |
| overlay2 디렉토리 직접 삭제 | Docker 메타데이터와 불일치 | `docker rmi`, `docker rm` 명령으로만 삭제 |
| 레이어 수 무시하고 이미지 빌드 | 성능 저하 인지 못함 | `docker history`로 레이어 수 모니터링 |
| device busy 오류 시 강제 umount | 데이터 손상 가능 | `umount -l` (lazy) 사용 또는 사용 프로세스 종료 후 처리 |
| 커널 3.x에서 overlay2 사용 | 커널 버전 미확인 | overlay2는 커널 4.0+ 필요, 이전 버전은 overlay (v1) 사용 |
