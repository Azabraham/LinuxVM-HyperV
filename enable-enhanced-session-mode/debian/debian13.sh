#!/bin/sh
#
# Enable Hyper-V Enhanced Session Mode on Debian 13 (Trixie)
# GNOME desktop using XRDP and Hyper-V VSOCK.
#
# Based on linux-vm-tools concepts.
#
# IMPORTANT:
# This script configures XRDP to use unencrypted RDP security
# over Hyper-V VSOCK. Do not expose this XRDP configuration
# to untrusted networks.
#

set -eu

###############################################################################
# Configuration
###############################################################################

XRDP_DIR="/etc/xrdp"
POLKIT_DIR="/etc/polkit-1/rules.d"

###############################################################################
# Pre-flight checks
###############################################################################

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if [ ! -f /etc/debian_version ]; then
    echo "ERROR: Debian installation not detected." >&2
    exit 1
fi

if ! grep -q '^13' /etc/debian_version; then
    echo "WARNING: This script was designed for Debian 13."
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: apt-get not found." >&2
    exit 1
fi

echo "Checking Debian package information..."

apt-get update

###############################################################################
# Kernel check
###############################################################################

if [ -L /vmlinuz ]; then
    kernel_link=$(readlink -f /vmlinuz)
    running_kernel=$(uname -r)

    case "$kernel_link" in
        *"$running_kernel")
            ;;
        *)
            echo "ERROR: A kernel reboot appears to be required." >&2
            echo "Reboot Debian and run this script again." >&2
            exit 1
            ;;
    esac
fi

###############################################################################
# Install required packages
###############################################################################

echo "Installing XRDP and supporting packages..."

apt-get install -y \
    xrdp \
    xorgxrdp \
    pipewire-module-xrdp \
    polkitd

###############################################################################
# Verify required configuration files
###############################################################################

if [ ! -f "$XRDP_DIR/xrdp.ini" ]; then
    echo "ERROR: xrdp.ini not found." >&2
    exit 1
fi

if [ ! -f "$XRDP_DIR/sesman.ini" ]; then
    echo "ERROR: sesman.ini not found." >&2
    exit 1
fi

###############################################################################
# Backup original configuration
###############################################################################

echo "Backing up XRDP configuration..."

if [ ! -f "$XRDP_DIR/xrdp.ini_orig" ]; then
    cp -p "$XRDP_DIR/xrdp.ini" "$XRDP_DIR/xrdp.ini_orig"
fi

if [ ! -f "$XRDP_DIR/sesman.ini_orig" ]; then
    cp -p "$XRDP_DIR/sesman.ini" "$XRDP_DIR/sesman.ini_orig"
fi

###############################################################################
# Create GNOME session wrapper
###############################################################################

if [ ! -f "$XRDP_DIR/startdebian.sh" ]; then

    cat > "$XRDP_DIR/startdebian.sh" << 'EOF'
#!/bin/sh

export XDG_CURRENT_DESKTOP=GNOME

exec /etc/xrdp/startwm.sh
EOF

    chmod 755 "$XRDP_DIR/startdebian.sh"
fi

###############################################################################
# Configure XRDP session manager
###############################################################################

echo "Configuring XRDP session manager..."

if grep -q '^EnableUserWindowManager=' "$XRDP_DIR/sesman.ini"; then
    sed -i \
        's|^EnableUserWindowManager=.*|EnableUserWindowManager=false|' \
        "$XRDP_DIR/sesman.ini"
fi

if grep -q '^DefaultWindowManager=' "$XRDP_DIR/sesman.ini"; then
    sed -i \
        's|^DefaultWindowManager=.*|DefaultWindowManager=startdebian.sh|' \
        "$XRDP_DIR/sesman.ini"
else
    echo "WARNING: DefaultWindowManager setting not found."
    echo "Check sesman.ini manually."
fi

###############################################################################
# Configure Hyper-V VSOCK transport
###############################################################################

echo "Configuring Hyper-V VSOCK..."

if grep -q '^port=' "$XRDP_DIR/xrdp.ini"; then
    sed -i \
        's|^port=.*|port=vsock://-1:3389|' \
        "$XRDP_DIR/xrdp.ini"
else
    echo "ERROR: XRDP port setting not found." >&2
    exit 1
fi

###############################################################################
# Configure XRDP security
###############################################################################

echo "Configuring XRDP security..."

# This is required by some older XRDP versions for VSOCK.
# Traffic is not encrypted by XRDP with these settings.
# Keep this configuration restricted to Hyper-V VSOCK.

if grep -q '^security_layer=' "$XRDP_DIR/xrdp.ini"; then
    sed -i \
        's|^security_layer=.*|security_layer=rdp|' \
        "$XRDP_DIR/xrdp.ini"
fi

if grep -q '^crypt_level=' "$XRDP_DIR/xrdp.ini"; then
    sed -i \
        's|^crypt_level=.*|crypt_level=none|' \
        "$XRDP_DIR/xrdp.ini"
fi

if grep -q '^bitmap_compression=' "$XRDP_DIR/xrdp.ini"; then
    sed -i \
        's|^bitmap_compression=.*|bitmap_compression=false|' \
        "$XRDP_DIR/xrdp.ini"
fi

###############################################################################
# Configure redirected drive mount name
###############################################################################

if grep -q '^FuseMountName=' "$XRDP_DIR/sesman.ini"; then
    sed -i \
        's|^FuseMountName=.*|FuseMountName=shared-drives|' \
        "$XRDP_DIR/sesman.ini"
fi

###############################################################################
# Configure Polkit rules
###############################################################################

echo "Configuring Polkit rules..."

mkdir -p "$POLKIT_DIR"

# Color management authorization for sudo group.

if [ ! -f "$POLKIT_DIR/45-allow-colord.rules" ]; then
    cat > "$POLKIT_DIR/45-allow-colord.rules" << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.color-manager.") === 0 &&
        subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
EOF
fi

# PackageKit repository refresh authorization for sudo group.

if [ ! -f "$POLKIT_DIR/46-allow-update-repo.rules" ]; then
    cat > "$POLKIT_DIR/46-allow-update-repo.rules" << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id === "org.freedesktop.packagekit.system-sources-refresh" &&
        subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
EOF
fi

# Power management authorization for sudo group.

if [ ! -f "$POLKIT_DIR/47-allow-power-off.rules" ]; then
    cat > "$POLKIT_DIR/47-allow-power-off.rules" << 'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id === "org.freedesktop.login1.power-off" ||
         action.id === "org.freedesktop.login1.power-off-multiple-sessions" ||
         action.id === "org.freedesktop.login1.reboot" ||
         action.id === "org.freedesktop.login1.reboot-multiple-sessions" ||
         action.id === "org.freedesktop.login1.suspend" ||
         action.id === "org.freedesktop.login1.suspend-multiple-sessions" ||
         action.id === "org.freedesktop.login1.hibernate" ||
         action.id === "org.freedesktop.login1.hibernate-multiple-sessions") &&
        subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
EOF
fi

###############################################################################
# Hyper-V kernel modules
###############################################################################

echo "Configuring Hyper-V kernel modules..."

mkdir -p /etc/modprobe.d
mkdir -p /etc/modules-load.d

# VMware VSOCK blacklist.
# This is intended for Hyper-V-only installations.

if [ ! -f /etc/modprobe.d/blacklist-vmw_vsock_vmci_transport.conf ]; then
    echo "blacklist vmw_vsock_vmci_transport" \
        > /etc/modprobe.d/blacklist-vmw_vsock_vmci_transport.conf
fi

# Load Hyper-V socket support at boot.

if [ ! -f /etc/modules-load.d/hv_sock.conf ]; then
    echo "hv_sock" > /etc/modules-load.d/hv_sock.conf
fi

###############################################################################
# Enable XRDP services
###############################################################################

echo "Enabling XRDP services..."

systemctl unmask xrdp.service
systemctl unmask xrdp-sesman.service

systemctl enable xrdp.service
systemctl enable xrdp-sesman.service

###############################################################################
# Validate configuration
###############################################################################

echo "Checking XRDP configuration..."

xrdp --version

if command -v xrdp >/dev/null 2>&1; then
    echo "XRDP executable detected."
fi

###############################################################################
# Completion
###############################################################################

echo ""
echo "Installation configuration completed."
echo ""
echo "IMPORTANT:"
echo "1. Shut down your Debian VM."
echo "2. Open PowerShell as Administrator on Windows."
echo "3. Execute:"
echo ""
echo '   Set-VM "Debian" -EnhancedSessionTransportType HvSocket'
echo ""
echo "4. Start your Debian VM."
echo "5. Select Enhanced Session Mode when connecting."
echo ""
echo "If the connection fails, use the standard Hyper-V console"
echo "to inspect the XRDP services and configuration."
echo ""
