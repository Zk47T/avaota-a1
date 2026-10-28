#!/usr/bin/env bash
# RUN ON THE A733 BOARD (optional): networking without the RJ45 port, e.g. on the
# Orange Pi Zero 3W. Both boards have the same two USB-C ports:
#   - "power" port : 5V/3A in, USB 2.0 OTG data (Allwinner UDC, also FEL)
#   - "OTG" port   : USB 3.x DWC3, dual role via the HUSB311/FUSB302 Type-C
#                    controller (role follows the cable), DP alt mode
#
#   ./45-usb-net.sh dongle   USB-C GbE adapter (RTL8153 / AX88179) on the OTG port.
#                            Same network design as the Zero 4's RJ45.
#   ./45-usb-net.sh gadget   the board becomes a USB NIC (CDC-NCM) on a host PC/hub.
#                            Point-to-point link; the host bridges or NATs it.
#   ./45-usb-net.sh status
# Untested on hardware. The kernel options are all present in the redroid host
# kernel (CONFIG_USB_RTL8152=m, AX88179=y, DWC3_DUAL_ROLE=y, CONFIGFS_NCM=y,
# TYPEC_FUSB302=y).
set -euo pipefail
G=/sys/kernel/config/usb_gadget/farm

case "${1:-status}" in
dongle)
  sudo modprobe r8152 2>/dev/null || true          # RTL8153 (most USB-C GbE dongles)
  # make sure the DWC3 port is a host (it is the default role)
  for r in /sys/class/usb_role/*/role; do [ -f "$r" ] && echo host | sudo tee "$r" >/dev/null; done
  sleep 2; ip -br link | grep -E "^(enx|eth|usb)" || echo "no USB NIC yet: plug the dongle into the OTG (USB 3) port"
  echo "NetworkManager/ifupdown picks it up like a normal NIC (DHCP)."
  ;;
gadget)
  mountpoint -q /sys/kernel/config || sudo mount -t configfs none /sys/kernel/config
  # stable MACs derived from the SoC serial, so the host sees the same NIC every boot
  SER=$(tr -d '\0' < /proc/device-tree/serial-number 2>/dev/null || cat /etc/machine-id)
  H=$(echo -n "$SER" | md5sum | cut -c1-10)
  mac() { echo "$1:${H:0:2}:${H:2:2}:${H:4:2}:${H:6:2}:${H:8:2}"; }
  sudo sh -e <<SH
[ -d $G ] && { echo "" > $G/UDC 2>/dev/null || true; }
mkdir -p $G && cd $G
echo 0x1d6b > idVendor; echo 0x0104 > idProduct     # Linux Foundation multifunction gadget
mkdir -p strings/0x409; echo "$SER" > strings/0x409/serialnumber
echo "a733-farm" > strings/0x409/manufacturer; echo "redroid node" > strings/0x409/product
mkdir -p configs/c.1 functions/ncm.usb0
echo 250 > configs/c.1/MaxPower
echo $(mac 02) > functions/ncm.usb0/dev_addr
echo $(mac 06) > functions/ncm.usb0/host_addr
[ -e configs/c.1/ncm.usb0 ] || ln -s functions/ncm.usb0 configs/c.1/
SH
  UDC=$(ls /sys/class/udc | grep -m1 -i dwc3 || true)
  [ -n "$UDC" ] || UDC=$(ls /sys/class/udc | head -1)   # fallback: the USB 2.0 power-port UDC
  # Type-C should switch the role when a host is attached; force it if not
  for r in /sys/class/usb_role/*/role; do [ -f "$r" ] && echo device | sudo tee "$r" >/dev/null; done
  echo "$UDC" | sudo tee $G/UDC >/dev/null
  echo "gadget bound to $UDC; board side NIC: $(ls /sys/class/net | grep -m1 usb || echo usb0)"
  echo "give it an address (static or DHCP from the host side), e.g.:"
  echo "  sudo ip addr add 10.55.0.2/24 dev usb0 && sudo ip link set usb0 up && sudo ip route add default via 10.55.0.1"
  ;;
status)
  ls /sys/class/udc 2>/dev/null | sed 's/^/udc: /'
  for r in /sys/class/usb_role/*/role; do [ -f "$r" ] && echo "role $(dirname "$r" | xargs basename): $(cat "$r")"; done
  cat /sys/class/typec/port0/data_role 2>/dev/null | sed 's/^/typec data_role: /' || true
  ip -br link
  ;;
*) echo "usage: $0 dongle|gadget|status"; exit 1;;
esac
