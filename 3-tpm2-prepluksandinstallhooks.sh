#!/usr/bin/env bash
# Noah Bliss
# Some inspiration taken from https://github.com/morbitzer/linux-luks-tpm-boot/blob/master/seal-nvram.sh
MORTAR_FILE="/etc/mortar/mortar.env"
OLD_DIR="$PWD"
source "$MORTAR_FILE"
echo "Testing if secure boot is on and working."
od --address-radix=n --format=u1 /sys/firmware/efi/efivars/SecureBoot-*
read -p  "ENTER to continue only if the last number is a \"1\" and you are sure the TPM registers are as you want them." asdf
if (command -v luksmeta >/dev/null); then
	echo "Wiping any existing metadata in the luks keyslot."
	luksmeta wipe -d "$CRYPTDEV" -s "$SLOT"
fi
echo "Wiping any old luks key in the keyslot. (You'll need to enter a password.)"
cryptsetup luksKillSlot "$CRYPTDEV" "$SLOT"
read -p "If this is the first time running, do you want to attempt taking ownership of the tpm? (y/N): " takeowner
case "$takeowner" in
	[yY]*)
		read -s -r -p "Owner password: " OWNERPW
		echo
		if tpm2_takeownership --owner-passwd="$OWNERPW" 
		then
			echo "Owner password updated."
		else
			echo "Set owner password failed. Try allowing ownership in the BIOS."
			exit 1
		fi
		;;
esac

if (mkdir tmpramfs && mount tmpfs -t tmpfs -o size=1M,noexec,nosuid tmpramfs); then
	echo "Generating key..."
	dd bs=1 count=512 if=/dev/urandom of=tmpramfs/mortar.key
	chmod 700 tmpramfs/mortar.key
	cryptsetup luksAddKey "$CRYPTDEV" --key-slot "$SLOT" tmpramfs/mortar.key 
	echo "Sealing key to TPM..."
	PERMISSIONS="OWNERWRITE|READ_STCLEAR"
	if [ -z $OWNERPW ]; then read -s -r -p "Owner password: " OWNERPW; fi
	# Wipe index if it is populated.
	if ! [ -z $TPM2INDEX ] && (tpm2_nvlist | grep \($TPM2INDEX\) > /dev/null); then tpm2_nvrelease -i "$TPMINDEX" -o"$OWNERPW"; fi
	# Convert PCR format...
	PCRS=$(echo "-r""$BINDPCR" | sed 's/,/ -r/g') # this format may not be tpm2 compatible
	# Create new index sealed to PCRS. 
	if [ -z $TPM2INDEX ]; then # we use the first free index
		TPM2INDEX=$(tpm2_nvdefine -s `wc -c tmpramfs/mortar.key` ) ## I LEFT OFF HERE
		if [ $? -ne 0 ]; then echo "Failed to define TPM policy."; exit 1; fi
	else # we use the index specified
		tpm2_nvdefine --index="$TPM2INDEX" 
		if [ $? -ne 0 ]; then echo "Failed to define TPM policy in index $TPM2INDEX"; exit 1; fi
	fi
	if (tpm_nvdefine -i "$TPMINDEX" -s $(wc -c tmpramfs/mortar.key) -p "$PERMISSIONS" -o "$OWNERPW" -z $PCRS); then
		# Write key into the index...
		tpm_nvwrite -i "$TPMINDEX" -f tmpramfs/mortar.key -z --password="$OWNERPW"
	fi
	# Get rid of the key in the ramdisk.
	rm  tmpramfs/mortar.key
	umount -l tmpramfs
	rmdir tmpramfs
else
	echo "Failed to create tmpramfs for storing the key."
	exit 1
fi

echo "Adding new sha256 of the luks header to the mortar env file."
if [ -f "$HEADERFILE" ]; then rm "$HEADERFILE"; fi
cryptsetup luksHeaderBackup "$CRYPTDEV" --header-backup-file "$HEADERFILE"
HEADERSHA256=$(sha256sum "$HEADERFILE" | cut -f1 -d' ')
sed -i -e "/^HEADERSHA256=.*/{s//HEADERSHA256=$HEADERSHA256/;:a" -e '$!N;$!b' -e '}' "$MORTAR_FILE"
if [ -f "$HEADERFILE" ]; then rm "$HEADERFILE"; fi

# Figure out our distribuition.
source /etc/os-release
tpmverdir='tpm1.2'
# Defer to tpm and distro-specific install script.
if [ -d "$OLD_DIR/""res/""$ID/""$tpmverdir/" ]; then
	cd "$OLD_DIR/""res/""$ID/""$tpmverdir/"
	echo "Distribution: $ID"
	echo "Installing kernel update and initramfs build scripts with mortar.env values..."
	bash install.sh # Start in new process so we don't get dropped to another directory. 
else
	echo "Distribution: $ID"
	echo "Could not find scripts for your distribution."
fi

