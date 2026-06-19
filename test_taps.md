```bash
chmod +x setup_lab.sh
sudo tcpdump -i br0 -e -vv
```

``` python
sudo python3
>>> from scapy.all import *
>>> pkt = Ether(dst="ff:ff:ff:ff:ff:ff", src="aa:bb:cc:dd:ee:01", type=0x0806) / ARP(
...     op=1,  # request
...     hwsrc="aa:bb:cc:dd:ee:01", psrc="10.0.0.1",
...     hwdst="00:00:00:00:00:00", pdst="10.0.0.2"
... )
>>> sendp(pkt, iface="tap0")
```
