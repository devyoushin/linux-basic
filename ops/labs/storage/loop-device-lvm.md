# Loop Device LVM Lab

파일을 block device처럼 사용해 LVM 흐름을 연습합니다.

## 실습 흐름

```bash
dd if=/dev/zero of=/tmp/lvm-lab.img bs=1M count=512
sudo losetup -fP /tmp/lvm-lab.img
losetup -a
```

이후 loop device를 대상으로 `pvcreate`, `vgcreate`, `lvcreate`, `mkfs.xfs`, `mount` 흐름을 실습합니다.

## 정리

```bash
sudo umount /mnt/lvm-lab
sudo lvremove <vg>/<lv>
sudo vgremove <vg>
sudo pvremove <loop-device>
sudo losetup -d <loop-device>
rm -f /tmp/lvm-lab.img
```

명령은 시스템에 실제 block device를 만들 수 있으므로 실습 VM에서만 진행합니다.
