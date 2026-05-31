# 대량 데이터 전송 전략: rsync, 병렬 전송, 파이프라인

## 1. 개요

수십~수백 GB 이상의 데이터를 전송할 때 단순 `cp`나 `scp`는 한계가 있다. 단일 스트림은 CPU 1코어와 네트워크 대역폭을 낭비 없이 활용하지 못하고, 중단 후 재시작 시 처음부터 다시 복사해야 한다. 이 문서는 `rsync`의 핵심 동작 원리, 멀티프로세스 병렬화, `tar` 파이프라인, 클라우드 환경에서의 고속 전송 전략을 다룬다.

---

## 2. 설명

### 2.1 rsync 핵심 원리

rsync는 **델타 전송 알고리즘**을 사용한다. 파일 전체를 보내지 않고, 송신측·수신측의 청크(chunk) 해시를 비교해 변경된 블록만 전송한다.

```
[송신측]                          [수신측]
파일 → 블록 분할 → 해시 요청 → 수신측 해시와 비교 → 변경 블록만 전송
```

**기본 옵션 정리**

```bash
rsync -avz \
  --progress \          # 파일별 진행상황 출력
  --stats \             # 전송 완료 후 통계 출력
  /src/dir/ user@remote:/dst/dir/
# -a: archive 모드 (권한/소유자/타임스탬프/심볼릭링크 유지)
# -v: verbose
# -z: 전송 중 gzip 압축 (CPU-bound vs 네트워크-bound 상황에 따라 선택)
```

> **주의**: `/src/dir`와 `/src/dir/`는 다르다. 슬래시 없으면 디렉토리 자체를, 슬래시 있으면 디렉토리 *내용*을 복사한다.

**자주 쓰는 고급 옵션**

```bash
rsync -avz \
  --partial \           # 중단된 파일을 부분 저장 (재시작 시 이어받기)
  --append-verify \     # 파일 끝에 추가 후 체크섬 검증
  --checksum \          # 타임스탬프 대신 MD5로 변경 감지 (정확하지만 느림)
  --exclude='*.log' \   # 특정 파일 제외
  --exclude='.git/' \   # 디렉토리 제외
  --bwlimit=100000 \    # 대역폭 제한 (KB/s), 운영 중 서버에서 유용
  --delete \            # 수신측에만 있는 파일 삭제 (미러링)
  /src/ user@remote:/dst/
```

**SSH 터널 최적화**

```bash
rsync -avz \
  -e "ssh -T -c aes128-ctr -o Compression=no -x" \
  # -T: pseudo-tty 비활성화
  # aes128-ctr: 암호화 오버헤드 최소화 (AES-NI 하드웨어 가속 활용)
  # Compression=no: rsync -z와 이중 압축 방지
  /src/ user@remote:/dst/
```

---

### 2.2 멀티프로세스 병렬 전송

rsync는 기본적으로 **단일 스트림**이다. 파일이 많고 네트워크 대역폭이 충분하면 병렬화로 전송 속도를 크게 높일 수 있다.

#### 방법 1: GNU Parallel + rsync

```bash
# 디렉토리 목록을 나눠 병렬 rsync 실행
ls /src/ | parallel -j 4 \
  rsync -avz /src/{}/ user@remote:/dst/{}/
# -j 4: 동시에 4개 rsync 프로세스 실행
# {}: parallel이 치환하는 입력값
```

```bash
# 파일 목록을 직접 분산하는 방법 (대용량 단일 디렉토리)
find /src -maxdepth 1 -mindepth 1 -type d | \
  parallel -j 8 rsync -az {} user@remote:/dst/
```

#### 방법 2: xargs + rsync

GNU Parallel이 없는 환경에서 사용한다.

```bash
find /src -maxdepth 1 -mindepth 1 -type d -print0 | \
  xargs -0 -P 4 -I{} \
  rsync -az {}/ user@remote:/dst/{}/
# -P 4: 최대 4개 프로세스 병렬 실행
# -I{}: 입력값 치환 문자열
```

#### 방법 3: rsync --files-from으로 파일 목록 분할

```bash
# 전체 파일 목록 생성 후 N등분
find /src -type f > /tmp/all_files.txt
split -n l/4 /tmp/all_files.txt /tmp/chunk_
# l/4: 줄 단위로 4등분

# 각 청크를 별도 rsync로 병렬 실행
for chunk in /tmp/chunk_*; do
  rsync -avz \
    --files-from="$chunk" \
    /src/ user@remote:/dst/ &   # 백그라운드 실행
done
wait   # 모든 백그라운드 작업 완료 대기
echo "전송 완료"
```

---

### 2.3 tar 파이프라인 전송

소켓 오버헤드를 최소화하고 단일 스트림으로 최대 처리량을 내야 할 때 유용하다. 파일 수가 수백만 개인 경우 rsync보다 `tar` 파이프가 빠를 수 있다 (rsync는 파일마다 메타데이터 교환 비용이 발생).

#### tar + SSH

```bash
# 송신측에서 실행
tar -cf - /src/ | \
  ssh user@remote "tar -xf - -C /dst/"
# -cf -: stdout으로 tar 스트림 출력
# -xf -: stdin에서 tar 스트림 수신

# 압축 추가 (CPU 여유 있고 네트워크가 병목일 때)
tar -czf - /src/ | \
  ssh -C user@remote "tar -xzf - -C /dst/"
```

#### tar + netcat (SSH 오버헤드 제거, 동일 VPC/내부망)

```bash
# 수신측에서 먼저 실행
nc -l 9999 | tar -xf - -C /dst/

# 송신측에서 실행
tar -cf - /src/ | nc remote-host 9999
```

> **주의**: netcat은 암호화가 없다. 외부 인터넷이나 보안이 필요한 구간에서는 반드시 SSH 터널을 사용한다.

#### pv로 진행상황 모니터링

```bash
tar -cf - /src/ | \
  pv -s $(du -sb /src/ | awk '{print $1}') | \  # 예상 크기 기반 진행률
  ssh user@remote "tar -xf - -C /dst/"
# pv: pipe viewer, 처리량·남은 시간 실시간 출력
```

---

### 2.4 멀티스트림 병렬 압축 전송

#### pigz (병렬 gzip)

```bash
tar -cf - /src/ | \
  pigz -p 8 | \          # 8코어로 병렬 압축
  ssh user@remote "pigz -d | tar -xf - -C /dst/"
# pigz: parallel gzip, 단일 gzip보다 N코어만큼 빠름
```

#### lz4 (초고속 압축, 낮은 CPU 비용)

```bash
tar -cf - /src/ | \
  lz4 | \                # 압축률보다 속도 우선 (gzip의 5~10배 빠름)
  ssh user@remote "lz4 -d | tar -xf - -C /dst/"
```

**압축 알고리즘 선택 기준**

| 상황 | 추천 |
|---|---|
| 네트워크가 병목 (100Mbps 이하) | `gzip -1` 또는 `lz4` |
| 네트워크 충분, CPU가 병목 | 압축 없음 (`-z` 제거) |
| CPU 충분, 네트워크 느림 | `pigz -p N` (고압축) |
| 텍스트/로그 대용량 | `zstd -T8` (압축률+속도 균형) |

---

### 2.5 클라우드 환경 고속 전송

#### S3: s5cmd (병렬 업로드)

```bash
# aws cli보다 수십 배 빠른 Go 기반 S3 클라이언트
s5cmd cp \
  --concurrency 64 \    # 동시 업로드 수
  --part-size 50        # 멀티파트 파트 크기 (MB)
  /src/* s3://my-bucket/dst/

# 디렉토리 전체 동기화
s5cmd sync /src/ s3://my-bucket/dst/
```

#### rclone (멀티클라우드 전송)

```bash
# S3 → GCS, S3 → S3, 로컬 → 클라우드 등 다양한 조합
rclone copy \
  --transfers 32 \      # 동시 전송 파일 수
  --checkers 16 \       # 동시 체크섬 검증 수
  --s3-upload-concurrency 8 \  # S3 멀티파트 병렬도
  --progress \
  /src/ remote:bucket/dst/

# 로컬 → S3 (AWS 프로파일 사용)
rclone sync \
  --transfers 16 \
  --fast-list \          # 목록 조회 API 호출 수 최소화
  /src/ s3:my-bucket/dst/
```

#### AWS DataSync (완관리형 대용량 마이그레이션)

```bash
# Terraform으로 DataSync 태스크 생성
resource "aws_datasync_task" "migration" {
  source_location_arn      = aws_datasync_location_nfs.src.arn
  destination_location_arn = aws_datasync_location_s3.dst.arn

  options {
    verify_mode        = "ONLY_FILES_TRANSFERRED"  # 전송 파일만 검증
    posix_permissions  = "PRESERVE"                # 권한 보존
    bytes_per_second   = 104857600                 # 100MB/s 제한
  }
}
```

---

### 2.6 전송 속도 측정 및 튜닝

**네트워크 처리량 측정 (iperf3)**

```bash
# 수신측
iperf3 -s

# 송신측 (10초간 8스트림 병렬 측정)
iperf3 -c remote-host -P 8 -t 10
```

**rsync 실제 전송률 확인**

```bash
rsync -avz --progress --stats /src/ user@remote:/dst/ 2>&1 | \
  grep -E "bytes|speed|total"
```

**커널 소켓 버퍼 튜닝 (대역폭 × RTT > 기본 버퍼일 때)**

```bash
# 10Gbps × 50ms RTT = 62.5MB → 기본 버퍼(4MB) 부족
sudo sysctl -w net.core.rmem_max=134217728    # 수신 버퍼 128MB
sudo sysctl -w net.core.wmem_max=134217728    # 송신 버퍼 128MB
sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728"
sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728"
# 영구 적용은 /etc/sysctl.conf 에 추가
```

---

## 3. 자주 하는 실수

| 실수 | 올바른 방법 |
|---|---|
| `rsync -z`를 항상 사용 | 이미 압축된 파일(jpg, gz, mp4)은 `-z` 제거. CPU만 낭비하고 속도는 동일 |
| 병렬 rsync 프로세스 수를 무한정 늘림 | 대역폭 / (파일당 평균 크기) 기준으로 산정. 수천 개의 소파일은 I/O 병목 발생 |
| 대용량 단일 파일을 tar+pipe로 전송 | 단일 큰 파일은 `rsync --partial`이 유리. 중단 시 이어받기 가능 |
| `--delete` 없이 rsync로 미러링 | 수신측에 삭제된 파일이 누적됨. 미러링 목적이면 반드시 `--delete` 추가 |
| netcat을 외부 인터넷 구간에 사용 | netcat은 평문 전송. 외부 구간은 SSH 터널 또는 TLS 래핑 필수 |
| 소켓 버퍼 튜닝 없이 고대역폭 WAN 사용 | BDP(대역폭×지연) 계산 후 `tcp_rmem/wmem` 확장 필요 |
| `aws s3 cp`로 수만 개 파일 업로드 | `s5cmd` 또는 `rclone`으로 대체. aws cli는 직렬 처리라 10~50배 느림 |
| 전송 완료 후 무결성 검증 생략 | `rsync --checksum` 재실행 또는 `md5sum`/`sha256sum` 비교로 검증 필수 |
