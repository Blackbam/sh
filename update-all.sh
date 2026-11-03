#!/bin/bash

# Automatically updates apt, snap and flatpak

echo "======================================"
echo " Starting System Update..."
echo "======================================"

echo -e "\n---> 1. Updating APT packages"
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y
sudo apt clean

echo -e "\n---> 2. Updating Snap packages"
sudo snap refresh

echo -e "\n---> 3. Updating Flatpak packages"
flatpak update -y

echo -e "\n======================================"
echo " All updates completed successfully! "
echo "======================================"

