# tcpdump HTTP Lab

로컬 HTTP 서버를 띄우고 loopback 트래픽을 tcpdump로 확인합니다.

## 터미널 1

```bash
python3 -m http.server 8080
```

## 터미널 2

```bash
sudo tcpdump -ni lo tcp port 8080
```

## 터미널 3

```bash
curl -v http://127.0.0.1:8080/
```

## 확인 포인트

- TCP handshake를 볼 수 있는가?
- HTTP 요청과 응답 방향을 구분할 수 있는가?
- `lo`와 실제 NIC 캡처의 차이를 설명할 수 있는가?
