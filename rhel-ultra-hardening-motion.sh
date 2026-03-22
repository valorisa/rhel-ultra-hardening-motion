#!/bin/bash
# rhel-ultra-hardening-motion.sh - Stack SELinux strict + svirt + seccomp + AppArmor
# Usage: curl -o rhel-ultra-hardening-motion.sh && chmod +x rhel-ultra-hardening-motion.sh && ./rhel-ultra-hardening-motion.sh
# REBOOT OBLIGATOIRE après étape 1 (relabel SELinux)

set -euo pipefail
export PHASE="${1:-1}"

echo "=== RHEL Ultra-Hardening Motion ($PHASE/2) - $(date) ==="

if [ "$PHASE" = "1" ] || [ "$PHASE" = "" ]; then
    echo "🚀 PHASE 1/2: Base + SELinux STRICT (REBOOT requis après)"
    dnf update -y
    dnf install -y wget curl policycoreutils-python-utils setroubleshoot-server audit
    systemctl disable --now postfix chronyd cups bluetooth ModemManager avahi-daemon rpcbind nfs-server 2>/dev/null || true
    
    cat > /etc/selinux/config << 'EOF'
SELINUX=enforcing
SELINUXTYPE=strict
EOF
    
    dnf install -y selinux-policy-strict selinux-policy-mls
    semodule -i /usr/share/selinux/{strict,mls}/*.pp 2>/dev/null || true
    touch /.autorelabel
    echo "✅ PHASE 1 OK ! REBOOT puis: $0 2"
    exit 0
fi

if [ "$PHASE" = "2" ]; then
    echo "🚀 PHASE 2/2: sVirt + Seccomp + AppArmor + Validation"
    sestatus | grep -q "Current mode: *enforcing" || { echo "❌ SELinux KO"; exit 1; }
    
    dnf groupinstall -y "Virtualization Host" --skip-broken
    dnf install -y libvirt qemu-kvm edk2-ovmf podman firewalld fail2ban lynis openscap-scanner scap-security-guide
    systemctl enable --now libvirtd firewalld
    
    semanage fcontext -a -t virt_image_t "/var/lib/libvirt/images(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t virt_log_t "/var/log/libvirt(/.*)?" 2>/dev/null || true
    restorecon -Rv /var/lib/libvirt /var/log/libvirt 2>/dev/null || true
    
    mkdir -p /etc/systemd/system.conf.d /etc/seccomp.d
    cat > /etc/systemd/system.conf.d/seccomp.conf << 'EOF'
[Manager]
DefaultSystemCallArchitectures=native
EOF
    
    cat > /etc/seccomp.d/ultra-strict.json << 'EOF'
{
  "defaultAction": "SCMP_ACT_ERRNO(EPERM)",
  "architectures": ["SCMP_ARCH_X86_64"],
  "syscalls": [
    {"name": "read", "action": "SCMP_ACT_ALLOW"},
    {"name": "write", "action": "SCMP_ACT_ALLOW"},
    {"name": "openat", "action": "SCMP_ACT_ALLOW"},
    {"name": "close", "action": "SCMP_ACT_ALLOW"},
    {"name": "statx", "action": "SCMP_ACT_ALLOW"},
    {"name": "fstat", "action": "SCMP_ACT_ALLOW"},
    {"name": "lseek", "action": "SCMP_ACT_ALLOW"},
    {"name": "exit", "action": "SCMP_ACT_ALLOW"},
    {"name": "exit_group", "action": "SCMP_ACT_ALLOW"}
  ]
}
EOF
    
    dnf install -y apparmor apparmor-utils
    systemctl enable --now apparmor
    aa-genprof /usr/sbin/nginx 2>/dev/null || true
    
    firewall-cmd --permanent --add-service=ssh --add-port=443/tcp
    firewall-cmd --reload
    systemctl enable --now fail2ban
    
    oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_cis \
      --results /root/cis-results.xml \
      --report /root/cis-report.html \
      /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml || true
    
    cat > /etc/cron.daily/ultra-hardening << 'EOF'
#!/bin/bash
lynis audit system >> /var/log/lynis.log 2>&1
sealert -a /var/log/audit/audit.log >> /var/log/selinux-alerts.log 2>&1
EOF
    chmod +x /etc/cron.daily/ultra-hardening
    
    echo "🎉 RHEL ULTRA-HARDENING-MOTION TERMINÉ !"
    sestatus | head -5
fi
