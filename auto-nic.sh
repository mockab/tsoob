#!/bin/bash

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or use sudo."
  exit 1
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

# Wipe the existing configuration on the interface
ip addr flush dev $interface

# Check for a USB drive with .ton file
ton_file_path=$(find /media/ -name '*.ton' -print -quit)

if [ -z "$ton_file_path" ]; then
  echo "No USB drive with .ton file found. Moving on..."
fi

# Extract predefined variables from .ton file
if [ -e "$ton_file_path" ]; then
  source "$ton_file_path"
fi

# Check if the .ton file contains netdiscover output variable
if [ -z "$TON_NETDISCOVER_OUTPUT" ]; then
  # Perform netdiscover on the second interface
  echo "Running netdiscover on $interface..."
  netdiscover_output=$(netdiscover -PNi $interface | { head -1 && pkill -f "netdiscover -PNi $interface"; } | egrep -o '([0-9]{1,3}\.){3}[0-9]{1,3}')
  echo "Found address $netdiscover_output on the other end of $interface"
else
  netdiscover_output="$TON_NETDISCOVER_OUTPUT"
  echo "Using predefined desination ip from .ton file: $netdiscover_output"
fi

# Extract the first three octets of the discovered network
discovered_network_octets=$(echo "$netdiscover_output" | awk -F. '{print $1"."$2"."$3}')

# Generate an initial IP address based on the discovered network
ip_address="${discovered_network_octets}.2"

while ip addr | grep -q "$ip_address/24" || [ "$ip_address" == "$netdiscover_output" ]; do
  echo "IP address $ip_address is in use. Incrementing..."
  ip_address=$(awk -F'.' '{print $1"."$2"."$3}' <<< "$ip_address")
  last_octet=$((10#${ip_address##*.}))  # Ensure the last octet is treated as base 10
  ip_address=$(awk -F'.' -v last_octet="$last_octet" '{print $1"."$2"."$3"."last_octet+1}' <<< "$ip_address")
done

# Assign the IP address to the interface
ip addr add $ip_address/24 dev $interface

# Enable tailscale and advertise route for ilo
tailscale up --accept-dns=false --advertise-routes=$netdiscover_output/32

echo "IP address $ip_address assigned to $interface on network $netdiscover_output."
