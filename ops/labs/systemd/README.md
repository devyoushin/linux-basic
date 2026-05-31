# systemd Lab

oneshot service와 timer를 실습합니다.

## 실습

```bash
sudo cp ops/labs/systemd/hello.service /etc/systemd/system/
sudo cp ops/labs/systemd/hello.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start hello.service
sudo systemctl start hello.timer
systemctl list-timers hello.timer
journalctl -u hello.service --no-pager
```

## 정리

```bash
sudo systemctl stop hello.timer
sudo rm -f /etc/systemd/system/hello.service /etc/systemd/system/hello.timer
sudo systemctl daemon-reload
```
