#!/bin/bash

# Verification Script for NVIDIA DGX Spark Multi-Node SGLang Setup
# This script verifies that all components are properly configured

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NODE1_IP="${NODE1_IP:-192.168.100.10}"
NODE2_IP="${NODE2_IP:-192.168.100.11}"
INTERFACE="${INTERFACE:-enp1s0f1np1}"
SGLANG_PORT="${SGLANG_PORT:-30000}"

# Determine script directory (resolves symlinks and relative paths)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

# Function to print messages
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

print_check() {
    echo -ne "  Checking $1... "
}

print_pass() {
    echo -e "${GREEN}PASS${NC}"
    ((CHECKS_PASSED++))
}

print_fail() {
    echo -e "${RED}FAIL${NC}"
    if [ -n "$1" ]; then
        echo -e "    ${RED}→ $1${NC}"
    fi
    ((CHECKS_FAILED++))
}

print_warn() {
    echo -e "${YELLOW}WARN${NC}"
    if [ -n "$1" ]; then
        echo -e "    ${YELLOW}→ $1${NC}"
    fi
    ((CHECKS_WARNED++))
}

print_info() {
    echo -e "    ${BLUE}→ $1${NC}"
}

# Check NVIDIA GPU
check_nvidia_gpu() {
    print_header "GPU Verification"
    
    print_check "NVIDIA driver"
    if nvidia-smi &>/dev/null; then
        print_pass
        print_info "$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -1)"
    else
        print_fail "nvidia-smi command failed"
    fi
    
    print_check "NVIDIA Container Toolkit"
    if command -v nvidia-container-cli &>/dev/null; then
        print_pass
    else
        print_fail "nvidia-container-cli not found"
    fi
}

# Check Docker
check_docker() {
    print_header "Docker Verification"
    
    print_check "Docker installation"
    if command -v docker &>/dev/null; then
        print_pass
        print_info "Docker version: $(docker --version | awk '{print $3}' | tr -d ',')"
    else
        print_fail "Docker not installed"
        return
    fi
    
    print_check "Docker daemon running"
    if docker info &>/dev/null; then
        print_pass
    else
        print_fail "Docker daemon not running"
        return
    fi
    
    print_check "Docker GPU access"
    # First check if NVIDIA runtime is configured, then optionally test with container
    if docker info 2>/dev/null | grep -q "Runtimes:.*nvidia"; then
        # NVIDIA runtime is configured, verify GPU access with container
        if docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi &>/dev/null; then
            print_pass
        else
            print_fail "Docker NVIDIA runtime configured but cannot access GPU"
        fi
    elif command -v nvidia-container-cli &>/dev/null && nvidia-container-cli info &>/dev/null; then
        print_pass
        print_info "NVIDIA Container CLI available (container test skipped)"
    else
        print_fail "Docker cannot access GPU - NVIDIA runtime not configured"
    fi
    
    print_check "Docker Compose"
    if command -v docker-compose &>/dev/null || docker compose version &>/dev/null; then
        print_pass
        if docker compose version &>/dev/null; then
            print_info "Docker Compose version: $(docker compose version --short 2>/dev/null || echo 'unknown')"
        else
            print_info "Docker Compose version: $(docker-compose --version | awk '{print $4}' | tr -d ',')"
        fi
    else
        print_fail "Docker Compose not installed"
    fi
    
    print_check "NVIDIA runtime configured"
    if docker info 2>/dev/null | grep -q "nvidia"; then
        print_pass
    else
        print_warn "NVIDIA runtime may not be default"
    fi
}

# Check Network
check_network() {
    print_header "Network Verification"
    
    print_check "Network interface ($INTERFACE)"
    if ip link show "$INTERFACE" &>/dev/null; then
        print_pass
        local state
        state=$(ip link show "$INTERFACE" | grep -oP "state \K\w+")
        print_info "Interface state: $state"
    else
        print_fail "Interface $INTERFACE not found"
        print_info "Available interfaces: $(ip link show | grep -E '^[0-9]+:' | awk '{print $2}' | tr -d ':' | tr '\n' ' ')"
    fi
    
    print_check "IP address assignment"
    local my_ip=""
    if ip addr show 2>/dev/null | grep -q "$NODE1_IP"; then
        my_ip="$NODE1_IP"
        print_pass
        print_info "This is Node 1 (IP: $NODE1_IP)"
    elif ip addr show 2>/dev/null | grep -q "$NODE2_IP"; then
        my_ip="$NODE2_IP"
        print_pass
        print_info "This is Node 2 (IP: $NODE2_IP)"
    else
        print_warn "Expected IP not found ($NODE1_IP or $NODE2_IP)"
    fi
    
    # Determine peer IP
    local peer_ip=""
    if [ "$my_ip" == "$NODE1_IP" ]; then
        peer_ip="$NODE2_IP"
    elif [ "$my_ip" == "$NODE2_IP" ]; then
        peer_ip="$NODE1_IP"
    fi
    
    if [ -n "$peer_ip" ]; then
        print_check "Peer node connectivity ($peer_ip)"
        if ping -c 3 -W 5 "$peer_ip" &>/dev/null; then
            print_pass
            local latency
            latency=$(ping -c 3 -W 5 "$peer_ip" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
            print_info "Average latency: ${latency}ms"
        else
            print_fail "Cannot reach peer node"
        fi
    fi
}

# Check SSH
check_ssh() {
    print_header "SSH Verification"
    
    print_check "SSH key exists"
    if [ -f "$HOME/.ssh/id_ed25519" ] || [ -f "$HOME/.ssh/id_rsa" ]; then
        print_pass
    else
        print_warn "No SSH key found"
    fi
    
    # Determine peer IP
    local peer_ip=""
    if ip addr show 2>/dev/null | grep -q "$NODE1_IP"; then
        peer_ip="$NODE2_IP"
    elif ip addr show 2>/dev/null | grep -q "$NODE2_IP"; then
        peer_ip="$NODE1_IP"
    fi
    
    if [ -n "$peer_ip" ]; then
        print_check "Passwordless SSH to peer"
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "$USER@$peer_ip" "echo success" &>/dev/null; then
            print_pass
        else
            print_warn "Passwordless SSH not configured"
        fi
    fi
}

# Check SGLang
check_sglang() {
    print_header "SGLang Verification"
    
    print_check "SGLang container image"
    if docker images | grep -q "lmsysorg/sglang"; then
        print_pass
    else
        print_warn "SGLang image not pulled (will be pulled on first run)"
    fi
    
    print_check "SGLang service on port $SGLANG_PORT"
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$SGLANG_PORT/health" 2>/dev/null | grep -q "200"; then
        print_pass
        print_info "SGLang is running and healthy"
    else
        print_warn "SGLang not running (start with 'docker compose up -d')"
    fi
    
    print_check "Docker Compose configuration"
    local compose_file
    compose_file="$REPO_ROOT/docker/compose.yml"
    if [ -f "$compose_file" ]; then
        print_pass
    else
        print_warn "compose.yml not found at expected location"
    fi
    
    print_check "Environment file"
    local env_file
    env_file="$REPO_ROOT/docker/.env"
    if [ -f "$env_file" ]; then
        print_pass
        if grep -q "HF_TOKEN" "$env_file" && ! grep -q "your_huggingface_token_here" "$env_file" && ! grep -q "REPLACE_WITH_YOUR" "$env_file"; then
            print_info "HF_TOKEN is configured"
        else
            print_warn "HF_TOKEN may not be configured properly"
        fi
    else
        print_warn ".env file not found (copy from .env.example)"
    fi
}

# Print summary
print_summary() {
    print_header "Summary"
    
    local total=$((CHECKS_PASSED + CHECKS_FAILED + CHECKS_WARNED))
    
    echo -e "  Total checks: $total"
    echo -e "  ${GREEN}Passed: $CHECKS_PASSED${NC}"
    echo -e "  ${YELLOW}Warnings: $CHECKS_WARNED${NC}"
    echo -e "  ${RED}Failed: $CHECKS_FAILED${NC}"
    echo ""
    
    if [ $CHECKS_FAILED -gt 0 ]; then
        echo -e "${RED}Some checks failed. Please review the issues above.${NC}"
        exit 1
    elif [ $CHECKS_WARNED -gt 0 ]; then
        echo -e "${YELLOW}Some warnings were found. Review them before proceeding.${NC}"
        exit 0
    else
        echo -e "${GREEN}All checks passed! Your system is ready for SGLang.${NC}"
        exit 0
    fi
}

# Main script
main() {
    echo ""
    echo "=========================================="
    echo " NVIDIA DGX Spark Multi-Node Setup Check"
    echo "=========================================="
    
    check_nvidia_gpu
    check_docker
    check_network
    check_ssh
    check_sglang
    print_summary
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi
