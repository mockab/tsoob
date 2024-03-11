#!/bin/bash

CONFIG_FILE="/etc/network-config"

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or use sudo."
  exit 1
fi

# Load the configuration file if it exists
if [ -e "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

# Find the second Ethernet interface
interface=$(ip -o link show | awk -F': ' '$2 !~ "lo" {print $2}' | awk 'NR==2{print $1}')

if [ -z "$interface" ]; then
  echo "No second Ethernet interface found."
  exit 1
fi

# Check if the interface is up, if not, bring it up
if ! ip link show dev "$interface" | grep -q "UP"; then
  echo "Bringing up $interface..."
  ip link set up dev "$interface"
  sleep 2 # Wait for the interface to be fully up
fi

# Check for a USB drive with .ton file
ton_file_path=$(find /media/ -name '*.ton' -print -quit)

if [ -z "$ton_file_path" ]; then
  echo "No USB drive with .ton file found. Moving on..."
fi

# Extract predefined variables from .ton file
if [ -e "$ton_file_path" ]; then
  source "$ton_file_path"
fi

# Check if the saved configuration still works
if [ -n "$SAVED_NETDISCOVER_OUTPUT" ]; then
  if ping -c 1 "$SAVED_NETDISCOVER_OUTPUT" &> /dev/null; then
    echo "Previous configuration is still valid. Skipping netdiscover."
    netdiscover_output="$SAVED_NETDISCOVER_OUTPUT"
  else
    echo "Previous configuration is not valid. Running netdiscover..."
    ip addr flush dev $interface
    netdiscover_output=$(netdiscover -PNi $interface | { head -1 && pkill -f "netdiscover -PNi $interface"; } | egrep -o '([0-9]{1,3}\.){3}[0-9]{1,3}')
  fi
else
  echo "No previous configuration found. Running netdiscover..."
  ip addr flush dev $interface
  netdiscover_output=$(netdiscover -PNi $interface | { head -1 && pkill -f "netdiscover -PNi $interface"; } | egrep -o '([0-9]{1,3}\.){3}[0-9]{1,3}')
fi

# Show the IP it found
echo "Found address $netdiscover_output on the other end of $interface"

# Extract the first three octets of the discovered network
discovered_network_octets=$(echo "$netdiscover_output" | awk -F. '{print $1"."$2"."$3}')

# Generate an initial IP address based on the discovered network
ip_address="${discovered_network_octets}.2"
while ip addr | grep -q "$ip_address/24" || [ "$ip_address" == "$netdiscover_output" ]; do
  echo "IP address $ip_address is in use. Incrementing..."
  last_octet=$((10#${ip_address##*.}))
  last_octet=$((last_octet + 1))
  ip_address="${discovered_network_octets}.${last_octet}"
done

# Save the current configuration to the file
echo "SAVED_NETDISCOVER_OUTPUT=$netdiscover_output" > "$CONFIG_FILE"

# Assign the IP address to the interface
ip addr flush dev $interface
ip addr add $ip_address/24 dev $interface

tailscale_options="--accept-dns=false"
if [ -n "$TON_TAILSCALE_OPTIONS" ]; then
  tailscale_options+=" $TON_TAILSCALE_OPTIONS"
fi

#Enable tailscale and advertise route for ilo
tailscale up $tailscale_options --advertise-routes=$netdiscover_output/32
 
echo "IP address $ip_address assigned to $interface on network $netdiscover_output."
