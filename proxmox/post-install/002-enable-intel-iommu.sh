#!/bin/bash
# Enables IOMMU for PCIe passthrough on Intel processors.
# IOMMU allows direct access of PCIe devices (e.g., GPU) to virtual machines,
# improving performance for tasks like GPU passthrough.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh"

require_root

# Add intel_iommu parameters to GRUB cmdline
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"/' /etc/default/grub

# Update GRUB to apply changes
update-grub

echo "IOMMU enabled. Reboot required for changes to take effect."
