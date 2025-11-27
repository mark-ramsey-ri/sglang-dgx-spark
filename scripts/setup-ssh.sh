#!/bin/bash

# SSH Setup Script for NVIDIA DGX Spark Multi-Node Configuration
# This script configures passwordless SSH between two DGX Spark nodes

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NODE1_IP="${NODE1_IP:-192.168.100.10}"
NODE2_IP="${NODE2_IP:-192.168.100.11}"
SSH_KEY_TYPE="${SSH_KEY_TYPE:-ed25519}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_$SSH_KEY_TYPE}"

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

# Check SSH key exists, create if not
ensure_ssh_key() {
    if [ -f "$SSH_KEY_PATH" ]; then
        print_msg "SSH key already exists at $SSH_KEY_PATH"
    else
        print_msg "Generating new SSH key..."
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        ssh-keygen -t "$SSH_KEY_TYPE" -f "$SSH_KEY_PATH" -N "" -q
        print_msg "SSH key generated at $SSH_KEY_PATH"
    fi
}

# Copy SSH key to peer node
copy_ssh_key() {
    local peer_ip=$1
    local username="${USER:-$(whoami)}"
    
    print_msg "Copying SSH key to $peer_ip..."
    print_msg "You may be prompted for the password on the remote node."
    
    # Check if we can already connect without password
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$username@$peer_ip" "echo success" 2>/dev/null; then
        print_msg "Already have passwordless SSH access to $peer_ip"
    else
        # Copy the key
        if ssh-copy-id -i "$SSH_KEY_PATH.pub" "$username@$peer_ip"; then
            print_msg "SSH key successfully copied to $peer_ip"
        else
            print_error "Failed to copy SSH key to $peer_ip"
            return 1
        fi
    fi
}

# Verify SSH connection
verify_ssh() {
    local peer_ip=$1
    local username="${USER:-$(whoami)}"
    
    print_msg "Verifying SSH connection to $peer_ip..."
    
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "$username@$peer_ip" "hostname" 2>/dev/null; then
        print_msg "${GREEN}SSH connection to $peer_ip successful!${NC}"
        return 0
    else
        print_error "SSH connection to $peer_ip failed"
        return 1
    fi
}

# Configure SSH client for better performance
configure_ssh_client() {
    local config_file="$HOME/.ssh/config"
    
    print_msg "Configuring SSH client..."
    
    # Backup existing config if present
    if [ -f "$config_file" ]; then
        cp "$config_file" "$config_file.backup"
    fi
    
    # Check if our config already exists
    if grep -q "# DGX Spark Multi-Node Configuration" "$config_file" 2>/dev/null; then
        print_msg "SSH client configuration already exists"
        return
    fi
    
    # Add configuration
    cat >> "$config_file" << EOF

# DGX Spark Multi-Node Configuration
Host spark-node1
    HostName $NODE1_IP
    User ${USER:-$(whoami)}
    IdentityFile $SSH_KEY_PATH
    StrictHostKeyChecking accept-new
    LogLevel ERROR

Host spark-node2
    HostName $NODE2_IP
    User ${USER:-$(whoami)}
    IdentityFile $SSH_KEY_PATH
    StrictHostKeyChecking accept-new
    LogLevel ERROR
EOF
    
    chmod 600 "$config_file"
    print_msg "SSH client configuration added to $config_file"
}

# Detect which node this is
detect_node() {
    # Check if NODE environment variable is set
    if [ -n "$NODE" ]; then
        echo "$NODE"
        return
    fi
    
    # Try to detect based on interface IP
    if ip addr show 2>/dev/null | grep -q "$NODE1_IP"; then
        echo "1"
    elif ip addr show 2>/dev/null | grep -q "$NODE2_IP"; then
        echo "2"
    else
        echo ""
    fi
}

# Main script
main() {
    print_msg "NVIDIA DGX Spark Multi-Node SSH Setup"
    print_msg "======================================"
    
    # Ensure SSH key exists
    ensure_ssh_key
    
    # Detect node
    NODE_NUM=$(detect_node)
    
    if [ -z "$NODE_NUM" ]; then
        echo ""
        echo "Which node is this?"
        echo "  1) Node 1 (IP: $NODE1_IP)"
        echo "  2) Node 2 (IP: $NODE2_IP)"
        read -rp "Enter choice [1/2]: " NODE_NUM
    fi
    
    if [ "$NODE_NUM" != "1" ] && [ "$NODE_NUM" != "2" ]; then
        print_error "Invalid node selection. Please choose 1 or 2."
        exit 1
    fi
    
    # Determine peer IP
    if [ "$NODE_NUM" == "1" ]; then
        PEER_IP="$NODE2_IP"
    else
        PEER_IP="$NODE1_IP"
    fi
    
    print_msg "This is Node $NODE_NUM"
    print_msg "Peer node IP: $PEER_IP"
    
    # Copy SSH key to peer
    print_msg ""
    print_msg "Copying SSH key to peer node..."
    copy_ssh_key "$PEER_IP"
    
    # Configure SSH client
    print_msg ""
    print_msg "Configuring SSH client..."
    configure_ssh_client
    
    # Verify connection
    print_msg ""
    print_msg "Verifying SSH connection..."
    verify_ssh "$PEER_IP"
    
    print_msg ""
    print_msg "SSH setup complete!"
    print_msg ""
    print_msg "You can now connect to the peer node with:"
    print_msg "  ssh spark-node1  (for Node 1)"
    print_msg "  ssh spark-node2  (for Node 2)"
    print_msg ""
    print_msg "Next steps:"
    print_msg "  1. Run this script on the other node"
    print_msg "  2. Verify the complete setup: ./verify-setup.sh"
    print_msg "  3. Start SGLang: cd docker && docker compose up -d"
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi
