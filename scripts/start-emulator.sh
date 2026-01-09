#!/bin/bash

set -e

source ./emulator-monitoring.sh

# The emulator console port.
EMULATOR_CONSOLE_PORT=5554
# The ADB port used to connect to ADB.
ADB_PORT=5555
OPT_MEMORY=${MEMORY:-8192}
OPT_CORES=${CORES:-4}
OPT_SKIP_AUTH=${SKIP_AUTH:-true}
OPT_ENABLE_VNC=${ENABLE_VNC:-false}
OPT_USE_SNAPSHOT=${USE_SNAPSHOT:-true}
AUTH_FLAG=
WINDOW_FLAG="-no-window"
SNAPSHOT_FLAG=""

# Start ADB server by listening on all interfaces.
echo "Starting the ADB server ..."
adb -a -P 5037 server nodaemon &

# Detect ip and forward ADB ports from the container's network
# interface to localhost.
LOCAL_IP=$(ip addr list eth0 | grep "inet " | cut -d' ' -f6 | cut -d/ -f1)
socat tcp-listen:"$EMULATOR_CONSOLE_PORT",bind="$LOCAL_IP",fork tcp:127.0.0.1:"$EMULATOR_CONSOLE_PORT" &
socat tcp-listen:"$ADB_PORT",bind="$LOCAL_IP",fork tcp:127.0.0.1:"$ADB_PORT" &

export USER=root

# Clean up stale lock files from previous sessions
echo "Cleaning up stale lock files..."
rm -f /data/*.lock /data/android.avd/*.lock 2>/dev/null || true
rm -rf /tmp/android-* 2>/dev/null || true

# Creating the Android Virtual Emulator.
TEST_AVD=$(avdmanager list avd | grep -c "android.avd" || true)
if [ "$TEST_AVD" == "1" ]; then
  echo "Use the exists Android Virtual Emulator ..."
else
  echo "Creating the Android Virtual Emulator ..."
  echo "Using package '$PACKAGE_PATH', ABI '$ABI' and device '$DEVICE_ID' for creating the emulator"
  echo no | avdmanager create avd \
    --force \
    --name android \
    --abi "$ABI" \
    --package "$PACKAGE_PATH" \
    --device "$DEVICE_ID"
fi

if [ "$OPT_SKIP_AUTH" == "true" ]; then
  AUTH_FLAG="-skip-adb-auth"
fi

# Check if KVM is available for hardware acceleration
ACCEL_FLAG=""
if [ ! -e /dev/kvm ]; then
  echo "WARNING: /dev/kvm not found. Using software emulation (slower)."
  ACCEL_FLAG="-no-accel"
else
  ACCEL_FLAG="-accel on"
fi

# Get screen resolution from environment or use optimized default
SCREEN_WIDTH=${SCREEN_WIDTH:-720}
SCREEN_HEIGHT=${SCREEN_HEIGHT:-1280}
SCREEN_DPI=${SCREEN_DPI:-280}

export DISPLAY=":0.0"

# Detect GPU and set appropriate mode
echo "Detecting GPU..."

# =============================================================================
# WSL2 + Docker GPU Rendering Limitation:
# =============================================================================
# WSL2 exposes GPU via D3D12 translation, NOT native OpenGL/Vulkan drivers.
# The Android emulator's "host" mode requires native GPU drivers which crash 
# in this environment.
#
# Available modes:
# - swangle_indirect: SwiftShader(Vulkan) + ANGLE(OpenGL ES) - RECOMMENDED
# - swiftshader_indirect: Pure SwiftShader - slower
# - host: Native GPU - CRASHES in WSL2/Docker
#
# For true GPU acceleration, run the emulator natively on Windows, not in Docker.
# =============================================================================

# Remove faulty NVIDIA Vulkan ICD that causes VK_ERROR_INCOMPATIBLE_DRIVER
if [ -f /usr/share/vulkan/icd.d/nvidia_icd.json ]; then
  echo "Removing incompatible NVIDIA Vulkan ICD (broken in WSL2)..."
  rm -f /usr/share/vulkan/icd.d/nvidia_icd.json 2>/dev/null || true
  rm -f /usr/share/vulkan/icd.d/nvidia_layers.json 2>/dev/null || true
fi

if nvidia-smi &>/dev/null; then
  echo "NVIDIA GPU detected:"
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
  echo ""
  echo "⚠️  NOTE: GPU detected but cannot be used for rendering in WSL2/Docker."
  echo "   WSL2 uses D3D12 translation which is incompatible with Android emulator's 'host' mode."
  echo "   Using 'swangle_indirect' (SwiftShader + ANGLE) for reliable rendering."
  echo ""
else
  echo "No NVIDIA GPU detected"
fi

# Use swangle_indirect - it's the best option for containerized environments
# SwiftShader provides Vulkan, ANGLE provides OpenGL ES
export GPU_MODE="${GPU_MODE:-swangle_indirect}"
echo "GPU mode: $GPU_MODE (optimized software rendering)"

# Allow override from environment
GPU_MODE=${GPU_MODE_OVERRIDE:-$GPU_MODE}

# Start Xvfb with configured resolution (higher color depth for better quality)
echo "Starting Xvfb..."
Xvfb "$DISPLAY" -screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x24 +extension GLX -nolisten tcp &
sleep 2

# Start VNC server and noVNC if enabled
if [ "$OPT_ENABLE_VNC" == "true" ]; then
  echo "Starting VNC server..."
  WINDOW_FLAG=""  # Show window when VNC is enabled
  
  # Start x11vnc with performance optimizations
  x11vnc -display "$DISPLAY" -forever -shared -rfbport 5900 -nopw \
    -xkb -noxrecord -noxfixes -noxdamage \
    -wait 5 -defer 5 \
    -threads -ncache 10 -ncache_cr &
  sleep 1
  
  # Start noVNC for web browser access
  echo "Starting noVNC web server on port 6080..."
  /usr/share/novnc/utils/launch.sh --vnc localhost:5900 --listen 6080 &
  
  echo "==================================================="
  echo "VNC is enabled!"
  echo "Access the emulator UI at: http://localhost:6080"
  echo "==================================================="
fi

# Handle snapshot persistence
if [ "$OPT_USE_SNAPSHOT" == "true" ]; then
  echo "Snapshots enabled for persistence"
  SNAPSHOT_FLAG=""  # Allow snapshots (don't use -no-snapshot)
else
  SNAPSHOT_FLAG="-no-snapshot"
fi

# Asynchronously write updates on the standard output
# about the state of the boot sequence.
wait_for_boot &

# Start the emulator
echo "Starting the emulator ..."
echo "OPTIONS:"
echo "SKIP ADB AUTH - $OPT_SKIP_AUTH"
echo "GPU           - $GPU_MODE"
echo "MEMORY        - $OPT_MEMORY"
echo "CORES         - $OPT_CORES"
echo "VNC ENABLED   - $OPT_ENABLE_VNC"
echo "SNAPSHOTS     - $OPT_USE_SNAPSHOT"
echo "RESOLUTION    - ${SCREEN_WIDTH}x${SCREEN_HEIGHT} @ ${SCREEN_DPI}dpi"
emulator \
  -avd android \
  -gpu "$GPU_MODE" \
  -memory $OPT_MEMORY \
  -no-boot-anim \
  -cores $OPT_CORES \
  -ranchu \
  $AUTH_FLAG \
  $ACCEL_FLAG \
  $WINDOW_FLAG \
  $SNAPSHOT_FLAG \
  -no-audio \
  -no-snapshot-load \
  -skin ${SCREEN_WIDTH}x${SCREEN_HEIGHT} || update_state "ANDROID_STOPPED"


  # -qemu \
  # -smp 8,sockets=1,cores=4,threads=2,maxcpus=8