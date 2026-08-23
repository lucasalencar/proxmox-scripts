#!/bin/bash

log_step "Installing useful commands and packages for system"
apt install htop btop iotop sysstat -y # Commands to monitor disk IO
