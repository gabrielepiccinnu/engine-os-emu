#!/bin/bash
# Resets the board's Bluetooth: the RTL8723BS controller on the UART stops
# answering after a while (HCI reset times out, "Opcode 0x0c03 failed: -110",
# and BlueZ reports "Authentication Failed" when powering it). Unbinding and
# rebinding its serdev drops and reloads the firmware, which brings it back.
# BlueZ in the chroot is stopped first and started again after, and the
# adapter powered.
#
#     az01-bt-reset.sh
P=$(pidof Engine)
kill $(cat /run/az01/run/az01-bluetoothd.pid 2>/dev/null) 2>/dev/null; pkill -x bluetoothd; sleep 1
echo serial0-0 > /sys/bus/serial/drivers/hci_uart_h5/unbind; sleep 2
echo serial0-0 > /sys/bus/serial/drivers/hci_uart_h5/bind; sleep 4
dmesg | grep -iE "bluetooth|hci0" | tail -n 4 | cut -c1-110
ls /sys/class/bluetooth/
nsenter -m -t $P -- chroot /opt/az01 sh -c '
setsid /usr/libexec/bluetooth/bluetoothd -n < /dev/null > /root/bluetoothd.log 2>&1 & echo $! > /run/az01-bluetoothd.pid
sleep 4
busctl --system set-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered b true 2>&1 | head -n 1
sleep 2
busctl --system get-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered'
tail -n 3 /opt/az01/root/bluetoothd.log | cut -c1-100
