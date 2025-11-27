#!/bin/bash

# Network Setup Script for NVIDIA DGX Spark Multi-Node Configuration
# This script configures the QSFP network interface for two-node communication

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
INTERFACE="${INTERFACE:-enp1s0f1np1}"
NODE1_IP="${NODE1_IP:-192.168.100.10}"
NODE2_IP="${NODE2_IP:-192.168.100.11}"
SUBNET_MASK="${SUBNET_MASK:-24}"

# Function to print messages
print_msg() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root or with sudo"
        exit 1
    fi
}

# Detect which node this is based on existing IP
detect_node() {
    # Check if NODE environment variable is set
    if [ -n "$NODE" ]; then
        echo "$NODE"
        return
    fi
    
    # Try to detect based on existing IP
    if ip addr show "$INTERFACE" 2>/dev/null | grep -q "$NODE1_IP"; then
        echo "1"
    elif ip addr show "$INTERFACE" 2>/dev/null | grep -q "$NODE2_IP"; then
        echo "2"
    else
        # Default to asking user
        echo ""
    fi
}

# Configure network interface
configure_network() {
    local node_num=$1
    local ip_addr
    
    if [ "$node_num" == "1" ]; then
        ip_addr="$NODE1_IP"
    else
        ip_addr="$NODE2_IP"
    fi
    
    print_msg "Configuring network for Node $node_num with IP $ip_addr"
    
    # Check if interface exists
    if ! ip link show "$INTERFACE" &>/dev/null; then
        print_error "Interface $INTERFACE not found. Please check your QSFP cable connection."
        print_msg "Available interfaces:"
        ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | tr -d ':'
        exit 1
    fi
    
    # Bring interface up
    print_msg "Bringing interface $INTERFACE up..."
    ip link set "$INTERFACE" up
    
    # Remove existing IP addresses on this interface
    ip addr flush dev "$INTERFACE" 2>/dev/null || true
    
    # Add new IP address
    print_msg "Assigning IP address $ip_addr/$SUBNET_MASK..."
    ip addr add "$ip_addr/$SUBNET_MASK" dev "$INTERFACE"
    
    print_msg "Network configuration complete!"
}

# Create netplan configuration (optional, for persistent config)
create_netplan() {
    local node_num=$1
    local ip_addr
    
    if [ "$node_num" == "1" ]; then
        ip_addr="$NODE1_IP"
    else
        ip_addr="$NODE2_IP"
    fi
    
    print_msg "Creating netplan configuration..."
    
    cat > /etc/netplan/40-cx7-multinode.yaml << EOF
network:
  version: 2
  ethernets:
    $INTERFACE:
      addresses:
        - $ip_addr/$SUBNET_MASK
      mtu: 9000
EOF
    
    chmod 600 /etc/netplan/40-cx7-multinode.yaml
    print_msg "Netplan configuration created at /etc/netplan/40-cx7-multinode.yaml"
    print_msg "Run 'sudo netplan apply' to apply the persistent configuration"
}

# Verify network configuration
verify_network() {
    local node_num=$1
    local peer_ip
    
    if [ "$node_num" == "1" ]; then
        peer_ip="$NODE2_IP"
    else
        peer_ip="$NODE1_IP"
    fi
    
    print_msg "Verifying network configuration..."
    
    # Show current IP configuration
    print_msg "Current IP configuration:"
    ip addr show "$INTERFACE"
    
    # Test connectivity to peer
    print_msg "Testing connectivity to peer ($peer_ip)..."
    if ping -c 3 -W 5 "$peer_ip" &>/dev/null; then
        print_msg "${GREEN}Successfully connected to peer node!${NC}"
    else
        print_warn "Could not reach peer node. Please ensure:"
        print_warn "  1. QSFP cable is properly connected"
        print_warn "  2. Network is configured on both nodes"
        print_warn "  3. Correct IP addresses are assigned"
    fi
}

# Main script
main() {
    print_msg "NVIDIA DGX Spark Multi-Node Network Setup"
    print_msg "=========================================="
    
    check_root
    
    # Detect or ask for node number
    NODE_NUM=$(detect_node)
    
    if [ -z "$NODE_NUM" ]; then
        echo ""
        echo "Which node is this?"
        echo "  1) Node 1 (will use IP $NODE1_IP)"
        echo "  2) Node 2 (will use IP $NODE2_IP)"
        read -rp "Enter choice [1/2]: " NODE_NUM
    fi
    
    if [ "$NODE_NUM" != "1" ] && [ "$NODE_NUM" != "2" ]; then
        print_error "Invalid node selection. Please choose 1 or 2."
        exit 1
    fi
    
    # Configure network
    configure_network "$NODE_NUM"
    
    # Ask about persistent configuration
    read -rp "Create persistent netplan configuration? [y/N]: " CREATE_NETPLAN
    if [ "$CREATE_NETPLAN" == "y" ] || [ "$CREATE_NETPLAN" == "Y" ]; then
        create_netplan "$NODE_NUM"
    fi
    
    # Verify
    verify_network "$NODE_NUM"
    
    print_msg ""
    print_msg "Setup complete!"
    print_msg "Next steps:"
    print_msg "  1. Run this script on the other node"
    print_msg "  2. Set up passwordless SSH: ./setup-ssh.sh"
    print_msg "  3. Verify the complete setup: ./verify-setup.sh"
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi
