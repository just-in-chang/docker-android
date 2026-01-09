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

# Configure ADB vendor keys if available
if [ -f /root/.android/adbkey ]; then
  export ADB_VENDOR_KEYS=/root/.android/adbkey
  echo "ADB vendor keys configured from /root/.android/adbkey"
fi

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
# Clean up stale X server lock files (critical for Xvfb restart)
rm -f /tmp/.X*-lock 2>/dev/null || true
rm -rf /tmp/.X11-unix 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

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
# GPU Rendering Detection:
# =============================================================================
# Detect if we're running in WSL2 or native Linux:
# - WSL2: Uses D3D12 translation, can't use native GPU - use software rendering
# - Native Linux: Can use host GPU acceleration directly
# =============================================================================

# Detect WSL2 environment
IS_WSL2=false
if grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; then
  IS_WSL2=true
fi
if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
  IS_WSL2=true
fi

if [ "$IS_WSL2" = true ]; then
  echo "WSL2 environment detected"
  # Remove faulty NVIDIA Vulkan ICD that causes VK_ERROR_INCOMPATIBLE_DRIVER in WSL2
  if [ -f /usr/share/vulkan/icd.d/nvidia_icd.json ]; then
    echo "Removing incompatible NVIDIA Vulkan ICD (broken in WSL2)..."
    rm -f /usr/share/vulkan/icd.d/nvidia_icd.json 2>/dev/null || true
    rm -f /usr/share/vulkan/icd.d/nvidia_layers.json 2>/dev/null || true
  fi
  
  if nvidia-smi &>/dev/null; then
    echo "NVIDIA GPU detected:"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
    echo ""
    echo "⚠️  NOTE: GPU detected but cannot be used for rendering in WSL2."
    echo "   WSL2 uses D3D12 translation which is incompatible with Android emulator's 'host' mode."
    echo "   Using 'swangle_indirect' (SwiftShader + ANGLE) for reliable rendering."
    echo ""
  fi
  # Use software rendering for WSL2
  export GPU_MODE="${GPU_MODE:-swangle_indirect}"
  echo "GPU mode: $GPU_MODE (optimized software rendering for WSL2)"
else
  echo "Native Linux environment detected"
  if nvidia-smi &>/dev/null; then
    echo "NVIDIA GPU detected:"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
    echo ""
    echo "✅ Using host GPU acceleration for rendering"
    export GPU_MODE="${GPU_MODE:-host}"
  else
    echo "No NVIDIA GPU detected, using software rendering"
    export GPU_MODE="${GPU_MODE:-swangle_indirect}"
  fi
  echo "GPU mode: $GPU_MODE"
fi

# Allow override from environment variable
GPU_MODE=${GPU_MODE_OVERRIDE:-$GPU_MODE}

# Start Xvfb with configured resolution (higher color depth for better quality)
echo "Starting Xvfb..."
Xvfb "$DISPLAY" -screen 0 ${SCREEN_WIDTH}x${SCREEN_HEIGHT}x24 +extension GLX -nolisten tcp &
XVFB_PID=$!

# Wait for Xvfb to be ready (up to 10 seconds)
XVFB_READY=false
for i in {1..20}; do
  if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    XVFB_READY=true
    echo "Xvfb started successfully on display $DISPLAY"
    break
  fi
  sleep 0.5
done

if [ "$XVFB_READY" = false ]; then
  echo "WARNING: Xvfb failed to start on display $DISPLAY"
  # Check if the process is still running
  if ! kill -0 $XVFB_PID 2>/dev/null; then
    echo "Xvfb process died, check for display conflicts"
  fi
fi

# Start VNC server and noVNC if enabled
if [ "$OPT_ENABLE_VNC" == "true" ]; then
  WINDOW_FLAG=""  # Show window when VNC is enabled
  
  if [ "$XVFB_READY" = true ]; then
    echo "Starting VNC server..."
    # Start x11vnc with low-latency gaming optimizations
    x11vnc -display "$DISPLAY" -forever -shared -rfbport 5900 -nopw \
      -xkb -noxrecord -noxfixes -noxdamage \
      -wait 1 -defer 1 \
      -threads -ncache 10 -ncache_cr \
      -pointer_mode 4 -input_skip 0 \
      -allinput -norepeat &
    sleep 1
    
    # Start noVNC for web browser access
    echo "Starting noVNC web server on port 6080..."
    /usr/share/novnc/utils/launch.sh --vnc localhost:5900 --listen 6080 &
    
    echo "==================================================="
    echo "VNC is enabled!"
    echo "Access the emulator UI at: http://localhost:6080"
    echo "==================================================="
  else
    echo "WARNING: VNC requested but Xvfb is not running. VNC will not be available."
    echo "The emulator will run in headless mode."
    WINDOW_FLAG="-no-window"
  fi
fi

# Set Qt platform plugin based on display availability
# This prevents "no Qt platform plugin could be initialized" errors
if [ "$XVFB_READY" = true ]; then
  export QT_QPA_PLATFORM=xcb
else
  export QT_QPA_PLATFORM=offscreen
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
  -no-metrics \
  -feature Vulkan \
  -feature GLDirectMem \
  -prop ro.adb.secure=0 \
  -prop ro.secure=0 \
  -prop ro.debuggable=1 \
  -prop service.adb.root=1 \
  -skin ${SCREEN_WIDTH}x${SCREEN_HEIGHT} || update_state "ANDROID_STOPPED"


  # -qemu \
  # -smp 8,sockets=1,cores=4,threads=2,maxcpus=8