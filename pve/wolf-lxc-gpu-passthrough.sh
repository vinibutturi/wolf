#!/bin/bash

# ==============================================================================
# Wolf - Proxmox LXC Docker Helper
# ==============================================================================

#Exit on cancel
set -e

# --- Color Variables ---
G='\e[32m'      # Green (Success)
B='\e[1;34m'    # Bold Blue (Stages)
C='\e[36m'      # Cyan (Info)
Y='\e[33m'      # Yellow (Warnings/Working)
R='\e[31m'      # Red (Errors)
BOLD='\e[1m'    # Bold
RESET='\e[0m'   # Reset
				 
# Installer Title
TITLE="Wolf - Proxmox LXC Docker Helper"

# Default variables
DEBIAN_VERSION=13
DEFAULT_NAME=wolf
DEFAULT_RAM=8192
DEFAULT_CPU=4
DEFAULT_HDSIZE=40
START_ONBOOT=1
SEARCH_PATTERN="debian-$DEBIAN_VERSION-standard"
LOG_FILE="/tmp/wolf_install.log"
LANG_GEN="en_US.UTF-8"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# GPU passthrough variables
NVIDIA_CONF="$SCRIPT_DIR/nvidia-passthrough.conf"
INTEL_CONF="$SCRIPT_DIR/intel-passthrough.conf"
AMD_CONF="$SCRIPT_DIR/amd-passthrough.conf"

# udev rules Variables
UDEV_HOST="/etc/udev/rules.d/85-wolf-virtual-inputs.rules"
UDEV_SOURCE="https://raw.githubusercontent.com/vinibutturi/wolf/refs/heads/stable/85-wolf.rules"

# Interface Functions
msg_box() { whiptail --title "$TITLE" --msgbox "$1" 10 60; }
input_box() { whiptail --title "$TITLE" --inputbox "$1" 10 60 "$2" 3>&1 1>&2 2>&3; }
password_box() { whiptail --title "$TITLE" --passwordbox "$1" 10 60 3>&1 1>&2 2>&3; }
menu_box() { whiptail --title "$TITLE" --menu "$1" 15 60 5 "${@:2}" 3>&1 1>&2 2>&3; }
confirm_box() { whiptail --title "$TITLE" --yesno "$1" 12 65; }			

# ==============================================================================
# Pre caching data
# ==============================================================================

# Next avaiable Container ID
echo -e "Initializing Wizard, please wait..${RESET}."
NEXT_ID=$(pvesh get /cluster/nextid)

# Storage list
mapfile -t STOR_LIST < <(pvesh get /storage --output-format yaml | grep "storage:" | awk '{print $2}')
STOR_OPTS=()
for s in "${STOR_LIST[@]}"; do
    if pvesh get /storage/"$s" --output-format yaml | grep -q "rootdir"; then
        STOR_OPTS+=("$s" "Storage Pool")
    fi
done

# Network bridge list
mapfile -t BR_LIST < <(pvesh get /nodes/localhost/network --type bridge --output-format yaml | grep "iface:" | awk '{print $2}')
BR_OPTS=()
for b in "${BR_LIST[@]}"; do BR_OPTS+=("$b" "Network Bridge"); done

# Create available GPU list
GPU_OPTS=()
declare -A FOUND_VENDORS
GPU_SCAN=$(lspci -nn | grep -Ei "0300|0302|0380")

while read -r line; do
    if echo "$line" | grep -qi "nvidia"; then
        FOUND_VENDORS["NVIDIA"]="NVIDIA"
    elif echo "$line" | grep -qi "intel"; then
        FOUND_VENDORS["INTEL"]="INTEL"
    elif echo "$line" | grep -qi "amd\|ati"; then
        FOUND_VENDORS["AMD"]="AMD"
    fi
done < <(echo "$GPU_SCAN")

# Validação dinâmica de arquivos (Fail Fast)
MISSING_FILES=()
declare -A GPU_MAP_FILES=( ["NVIDIA"]="$NVIDIA_CONF" ["INTEL"]="$INTEL_CONF" ["AMD"]="$AMD_CONF" )

for v in "${!FOUND_VENDORS[@]}"; do
    CONF_FILE="${GPU_MAP_FILES[$v]}"
    if [ ! -f "$CONF_FILE" ]; then
        MISSING_FILES+=($(basename "$CONF_FILE"))
    fi
done

if [ ${#MISSING_FILES[@]} -gt 0 ]; then
    echo -e "${R}[!] ERROR: GPU detected but config file is missing in $SCRIPT_DIR:${RESET}"
    for file in "${MISSING_FILES[@]}"; do echo -e "    - $file"; done
    exit 1
fi

# Monta o menu (Uma coluna)
for vendor in "${!FOUND_VENDORS[@]}"; do
    GPU_OPTS+=("$vendor" "")
done
[ ${#GPU_OPTS[@]} -gt 0 ] && GPU_OPTS+=("NONE" "")

clear

# ==============================================================================
# LXC DETAILS
# ==============================================================================

# CONTAINER TYPE (Forced to Privileged with Warning)
if ! whiptail --title "$TITLE" --yesno "At the moment Wolf is only fully supported on privileged LXC.\n\nThis script will create a PRIVILEGED LXC.\nDo it on your own risk.\n\nWould you like to proceed?" 12 65; then
    tput cnorm; echo "Installation cancelled by user."; exit 0
fi
CT_UNPRIV="0" # Variable for eventual unprivileged support

# LXC ID
CT_ID=$(input_box "Enter Container ID:" "$NEXT_ID")

# LXC Name
CT_NAME=$(input_box "Enter Hostname:" "$DEFAULT_NAME")

# PASSWORD
while true; do
    CT_PASSWORD=$(password_box "Set Root Password (Leave blank for autologin):")
    [ -z "$CT_PASSWORD" ] && break
    CT_PASSWORD_CONF=$(password_box "Confirm Root Password:")
    if [ "$CT_PASSWORD" == "$CT_PASSWORD_CONF" ]; then break; fi
    msg_box "Passwords do not match! Please try again."
done

# RAM
CT_RAM=$(input_box "RAM Amount (MiB):" "$DEFAULT_RAM")

# CPU
CT_CPU=$(input_box "CPU Cores:" "$DEFAULT_CPU")

# HD SIZE
CT_DISK=$(input_box "Disk Size (GiB):" "$DEFAULT_HDSIZE")

# STORAGE LOCATION
CT_STORAGE=$(menu_box "Select Storage:" "${STOR_OPTS[@]}")


# ==============================================================================
# NETWORK DETAILS
# ==============================================================================

# BRIDGE
CT_BRIDGE=$(menu_box "Select Network Bridge:" "${BR_OPTS[@]}")

# IP ADDRESS
NET_TYPE=$(menu_box "IP Configuration:" "1" "DHCP (Automatic)" "2" "Static (Manual)")
if [ "$NET_TYPE" == "2" ]; then
    CT_IP=$(input_box "IP Address (e.g., 192.168.1.50):" "")
    CT_MASK=$(input_box "CIDR Netmask (e.g., 24):" "24")
    CT_GW=$(input_box "Gateway IP:" "")
    CT_DNS=$(input_box "DNS Server:" "")
    IP_PART="ip=$CT_IP/$CT_MASK,gw=$CT_GW"
    DNS_FLAG="--nameserver $CT_DNS"
    IP_SUMMARY="$CT_IP/$CT_MASK"
    GW_SUMMARY="GATEWAY:        $CT_GW"
    DNS_SUMMARY="DNS SERVER:     $CT_DNS"
else
    IP_PART="ip=dhcp"
    DNS_FLAG=""
    IP_SUMMARY="Automatic (DHCP)"
    GW_SUMMARY=""
    DNS_SUMMARY=""
fi

# VLAN
CT_VLAN=$(input_box "VLAN Tag (Leave blank for none):" "")
VLAN_CONF=""
VLAN_SUMMARY=""
if [ -n "$CT_VLAN" ]; then
    VLAN_CONF=",tag=$CT_VLAN"
    VLAN_SUMMARY="VLAN:           $CT_VLAN"
fi

NET_CONF="name=eth0,bridge=$CT_BRIDGE,$IP_PART$VLAN_CONF"

# SSH CONFIGURATION
if [ -n "$CT_PASSWORD" ]; then
    SSH_PASS=$(whiptail --title "$TITLE" --yesno "Enable SSH Password Authentication?\n(Recommended: No if using SSH Keys; Yes for easier remote access)" 10 60 3>&1 1>&2 2>&3 && echo "yes" || echo "no")
else
    SSH_PASS="no"
fi

# ==============================================================================
# UDEV RULES CHECK
# ==============================================================================

if [ -f "$UDEV_HOST" ]; then
    UDEV_ACTION="existing"
    UDEV_SUMMARY="Existing"
else
    if whiptail --title "$TITLE" --yesno "The udev rules file is missing on the PVE host.\n($UDEV_HOST)\n\nThis is required for virtual input support.\nWould you like it to be added?" 13 65; then
        UDEV_ACTION="add"
        UDEV_SUMMARY="Add"
    else
        UDEV_ACTION="missing"
        UDEV_SUMMARY="!!! MISSING !!!"
    fi
fi

# ==============================================================================
# GPU SELECTION
# ==============================================================================

GPU_ACTION="none"
GPU_SUMMARY_TEXT="None"

if [ ${#GPU_OPTS[@]} -gt 0 ]; then
    SELECTED_GPU=$(menu_box "Detected GPUs. Select one for passthrough:" "${GPU_OPTS[@]}")
    if [ "$SELECTED_GPU" != "NONE" ] && [ -n "$SELECTED_GPU" ]; then
        GPU_ACTION="${SELECTED_GPU,,}"
        GPU_SUMMARY_TEXT="$SELECTED_GPU"
    fi
fi

# ==============================================================================
# FINAL CONFIRMATION
# ==============================================================================

NET_SUMMARY="NETWORK:        $IP_SUMMARY"
[ -n "$GW_SUMMARY" ] && NET_SUMMARY="$NET_SUMMARY\n$GW_SUMMARY"
[ -n "$DNS_SUMMARY" ] && NET_SUMMARY="$NET_SUMMARY\n$DNS_SUMMARY"
NET_SUMMARY="$NET_SUMMARY\nBRIDGE:         $CT_BRIDGE"
[ -n "$VLAN_SUMMARY" ] && NET_SUMMARY="$NET_SUMMARY\n$VLAN_SUMMARY"

SUMMARY_TEXT="Please confirm the settings before proceeding:
-----------------------------------------------------------
Debian Version: $DEBIAN_VERSION
ID:             $CT_ID
Hostname:       $CT_NAME
Type:           $([ "$CT_UNPRIV" == "1" ] && echo "Unprivileged" || echo "Privileged")
Resources:      $CT_CPU Cores / $CT_RAM MB RAM / $CT_DISK GB Disk
-----------------------------------------------------------
STORAGE:        $CT_STORAGE
$(echo -e "$NET_SUMMARY")
-----------------------------------------------------------
SSH PASS AUTH:  $SSH_PASS
-----------------------------------------------------------
UDEV RULES:     $UDEV_SUMMARY
GPU PASS:       $GPU_SUMMARY_TEXT
-----------------------------------------------------------
Do you want to start the creation now?"

if ! whiptail --title "$TITLE" --yesno "$SUMMARY_TEXT" 24 75; then
    tput cnorm; echo "Creation cancelled by user."; exit 0
fi

# ==============================================================================
# LXC CREATION
# ==============================================================================

> "$LOG_FILE"
FINAL_IP=""

cleanup_on_fail() {
    tput cnorm
    echo -e "\n${R}[!] ERROR: $1${RESET}"
    echo -e "${Y}[+] Cleaning up: Automatically removing failed container $CT_ID...${RESET}"
    pct stop "$CT_ID" >/dev/null 2>&1 || true
    pct destroy "$CT_ID" --purge >/dev/null 2>&1 || true
    echo -e "${G}[OK] Cleanup complete. Check $LOG_FILE for details.${RESET}"
    exit 1
}

tput cnorm
clear
echo -e "${G}=====================================================${RESET}"
echo -e "${G}        STARTING CREATION: $CT_NAME ($CT_ID)      ${RESET}"
echo -e "${G}=====================================================${RESET}\n"

# UDEV Rules
if [ "$UDEV_ACTION" == "add" ]; then
    echo -e "${B}[0/5]${RESET} ${C}Setting up PVE host udev rules...${RESET}"
    if curl -fsSL "$UDEV_SOURCE" -o "$UDEV_HOST"; then
        udevadm control --reload-rules && udevadm trigger
        echo -e "     ${G}[OK] udev rules added to PVE host.${RESET}"
    else
        echo -e "     ${R}[!] Failed to add udev rules on PVE host.${RESET}"
    fi
fi

# Template
echo -e "${B}[1/5]${RESET} ${C}Fetching Debian $DEBIAN_VERSION Template...${RESET}"
pveam update >> "$LOG_FILE" 2>&1
LATEST_TMPL=$(pveam available | grep "$SEARCH_PATTERN" | sort -r | head -n1 | awk '{print $2}')
if [ -z "$LATEST_TMPL" ]; then cleanup_on_fail "Template not found."; fi

if ! pveam list local | grep -q "$(basename "$LATEST_TMPL")"; then
    echo -e "     ${Y}Downloading template (please wait)...${RESET}"
    pveam download local "$LATEST_TMPL" >> "$LOG_FILE" 2>&1
fi

# Create LXC
echo -e "\n${B}[2/5]${RESET} ${C}Creating LXC Container...${RESET}"
PW_PARAM=""
[ -n "$CT_PASSWORD" ] && PW_PARAM="--password $CT_PASSWORD"

if pct create "$CT_ID" "local:vztmpl/$(basename "$LATEST_TMPL")" \
    --hostname "$CT_NAME" $PW_PARAM \
    --storage "$CT_STORAGE" \
    --rootfs "$CT_STORAGE:$CT_DISK" \
    --memory "$CT_RAM" --cores "$CT_CPU" \
    --net0 "$NET_CONF" $DNS_FLAG \
    --features nesting=1,keyctl=1 \
    --unprivileged "$CT_UNPRIV" \
    --onboot "$START_ONBOOT" >> "$LOG_FILE" 2>&1; then
	
	LXC_CONFIG="/etc/pve/lxc/${CT_ID}.conf"
	case "$GPU_ACTION" in
		nvidia)
			cat "$NVIDIA_CONF" >> "$LXC_CONFIG"
			echo -e "     ${G}[OK] Injected NVIDIA passthrough...${RESET}";;
		intel)
			cat "$INTEL_CONF" >> "$LXC_CONFIG"
			echo -e "     ${G}[OK] Injected Intel passthrough...${RESET}";;
		amd)
			cat "$AMD_CONF" >> "$LXC_CONFIG"
			echo -e "     ${G}[OK] Injected AMD passthrough...${RESET}";;
	esac
	
	echo -e "     ${Y}[+] Starting container with GPU configuration...${RESET}"
    if pct start "$CT_ID" >> "$LOG_FILE" 2>&1; then
        echo -e "     ${G}[OK] Container $CT_ID created and started successfully.${RESET}"
    else
        cleanup_on_fail "Failed to start container $CT_ID. Likely a GPU configuration or driver issue. Check $LOG_FILE."
    fi
else
    cleanup_on_fail "Failed to create LXC container. Check $LOG_FILE for details."
fi

# Network Validation
echo -e "\n${B}[3/5]${RESET} ${C}Validating Network...${RESET}"
for i in {1..30}; do
    TMP_IP=$(pct exec "$CT_ID" -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -n 1 || true)
    TMP_IP=$(echo "$TMP_IP" | tr -d '[:space:]')

    if [ -n "$TMP_IP" ]; then 
        FINAL_IP="$TMP_IP"
        echo -e "     ${G}[OK] IP Found: $FINAL_IP${RESET}"
        break
    fi
    echo -n -e "${Y}.${RESET}"
    sleep 2
done

if [ -z "$FINAL_IP" ]; then
    cleanup_on_fail "Network validation failed. IP not detected after 60 seconds."
fi

# ==============================================================================
# LXC SETUP
# ==============================================================================

# Fix locales
echo -e "\n${B}[4/5]${RESET} ${C}Updating System & Installing Docker...${RESET}"
echo -e "     ${Y}Fixing Locales...${RESET}"

pct exec "$CT_ID" -- bash -c "sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen" >> "$LOG_FILE" 2>&1
pct exec "$CT_ID" -- bash -c "locale-gen en_US.UTF-8" >> "$LOG_FILE" 2>&1
pct exec "$CT_ID" -- bash -c "update-locale LANG=en_US.UTF-8" >> "$LOG_FILE" 2>&1

# System Update & Full Upgrade
echo -e "     ${Y}Updating and Upgrading system packages (please wait)...${RESET}"
pct exec "$CT_ID" -- bash -c "export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8; export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y dist-upgrade" >> "$LOG_FILE" 2>&1

# Install Core Dependencies
echo -e "     ${Y}Installing dependencies...${RESET}"
pct exec "$CT_ID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y curl openssh-server" >> "$LOG_FILE" 2>&1

# Docker Install
echo -e "     ${Y}Running Docker installation script...${RESET}"
pct exec "$CT_ID" -- bash -c "export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8; curl -fsSL https://get.docker.com | sh" >> "$LOG_FILE" 2>&1

# Validate docker service
if pct exec "$CT_ID" -- docker --version >/dev/null 2>&1; then
    echo -e "     ${G}[OK] Docker installed successfully!${RESET}"
else
    cleanup_on_fail "Docker installation failed. Check $LOG_FILE for details."
fi

# Security & SSH Configuration
echo -e "\n${B}[5/5]${RESET} ${C}Configuring Security & SSH...${RESET}"

# Passwordless Console Autologin
if [ -z "$CT_PASSWORD" ]; then
    echo -e "     ${Y}No password set. Enabling Console Autologin...${RESET}"
    pct exec "$CT_ID" -- passwd -d root >> "$LOG_FILE" 2>&1
    pct exec "$CT_ID" -- bash -c "mkdir -p /etc/systemd/system/container-getty@1.service.d/"
    pct exec "$CT_ID" -- bash -c "echo -e '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200 linux' > /etc/systemd/system/container-getty@1.service.d/override.conf"
    pct exec "$CT_ID" -- systemctl daemon-reload >> "$LOG_FILE" 2>&1
    pct exec "$CT_ID" -- systemctl restart container-getty@1 >> "$LOG_FILE" 2>&1
fi

# SSH Password Authentication
if [ "$SSH_PASS" == "yes" ]; then
    echo -e "     ${G}Enabling SSH Password Authentication...${RESET}"
    pct exec "$CT_ID" -- sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    pct exec "$CT_ID" -- sed -i 's/#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    pct exec "$CT_ID" -- sed -i 's/#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
else
    echo -e "     ${Y}Disabling SSH Password Authentication (Keys Only)...${RESET}"
    pct exec "$CT_ID" -- sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    pct exec "$CT_ID" -- sed -i 's/#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    
    if [ -z "$CT_PASSWORD" ]; then
         pct exec "$CT_ID" -- sed -i 's/#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
    fi
fi

pct exec "$CT_ID" -- systemctl restart ssh >> "$LOG_FILE" 2>&1
pct exec "$CT_ID" -- reboot >> "$LOG_FILE" 2>&1

# ==============================================================================
# FINAL SUMMARY
# ==============================================================================

tput cnorm
echo -e "\n${G}=====================================================${RESET}"
echo -e "${G}                INSTALLATION COMPLETE!               ${RESET}"
echo -e "${G}=====================================================${RESET}"
echo -e "\n${BOLD}CONTAINER DETAILS:${RESET}"
echo -e "  ${C}ID:${RESET}            $CT_ID"
echo -e "  ${C}Hostname:${RESET}      $CT_NAME"
echo -e "  ${C}IP Address:${RESET}    ${BOLD}${FINAL_IP:-Not Detected (Check Proxmox GUI)}${RESET}"
echo -e "  ${C}Status:${RESET}        Docker Engine Installed & Running"
echo -e "\n${G}-----------------------------------------------------${RESET}"
echo -e "Full installation logs available at: ${Y}$LOG_FILE${RESET}"
echo -e "${G}=====================================================${RESET}\n"

exit 0
