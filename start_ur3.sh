#!/usr/bin/env bash
# UR3 driver launcher.
# Correct order:
#   1) Pre-flight checks (net / IP / pendant program loaded)
#   2) Start ros2 launch  (PC begins listening on 50001-50003)
#   3) Operator presses Play on the pendant -> URCap connects to PC

set -e
ROBOT_IP="${ROBOT_IP:-192.168.1.101}"
REVERSE_IP="${REVERSE_IP:-192.168.1.102}"
UR_TYPE="${UR_TYPE:-ur3e}"   # URControl 5.13.x => e-Series; override with UR_TYPE=ur3 if needed

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YEL}[WAIT]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

dash() {
  python3 - "$ROBOT_IP" "$1" <<'PY'
import socket, sys, time
ip, cmd = sys.argv[1], sys.argv[2]
try:
    s = socket.socket(); s.settimeout(2.0); s.connect((ip, 29999))
    s.recv(1024)
    s.sendall((cmd + "\n").encode()); time.sleep(0.2)
    print(s.recv(2048).decode().strip())
    s.close()
except Exception as e:
    print(f"ERROR: {e}")
PY
}

echo "=============================================="
echo " UR3 Driver Launcher  (robot=$ROBOT_IP, pc=$REVERSE_IP)"
echo "=============================================="

# 1) Source ROS  (disable -e while sourcing — colcon scripts trip strict modes)
set +e
if [[ -z "${ROS_DISTRO:-}" ]]; then
  info "Sourcing /opt/ros/jazzy/setup.bash"
  source /opt/ros/jazzy/setup.bash
fi
if [[ -f "$HOME/ros2_ws_cap/install/setup.bash" ]]; then
  source "$HOME/ros2_ws_cap/install/setup.bash"
fi
set -e
ok "ROS_DISTRO=$ROS_DISTRO"

# 2) Network
if ping -c 1 -W 1 "$ROBOT_IP" >/dev/null 2>&1; then
  ok "Ping $ROBOT_IP OK"
else
  err "Cannot ping $ROBOT_IP"; exit 1
fi
if ip -4 addr show | grep -q "inet $REVERSE_IP/"; then
  ok "PC has IP $REVERSE_IP"
else
  err "PC does NOT have $REVERSE_IP"; ip -4 addr show | grep inet; exit 1
fi

# 2.5) Cleanup any leftover UR driver processes from previous failed launches
# (these hold connections to the robot's primary interface and cause
#  "Could not get configuration package within timeout" on the next try)
LEFTOVER=$(pgrep -f "ur_robot_driver|ros2_control_node" | grep -v $$ || true)
if [[ -n "$LEFTOVER" ]]; then
  warn "Killing leftover driver processes: $LEFTOVER"
  pkill -9 -f "ur_robot_driver" 2>/dev/null || true
  pkill -9 -f "ros2_control_node" 2>/dev/null || true
  pkill -9 -f "ros2 launch ur_robot_driver" 2>/dev/null || true
  sleep 3   # let robot release primary-interface slots
  ok "Cleaned up"
fi

# 3) Pre-flight: confirm pendant has a program loaded and is in safe state
info "Checking pendant state..."
rmode=$(dash "robotmode")
smode=$(dash "safetymode")
prog=$(dash "get loaded program")
running=$(dash "running")
echo "   robotmode    : $rmode"
echo "   safetymode   : $smode"
echo "   loaded prog  : $prog"
echo "   running      : $running"

if [[ "$rmode" != *"RUNNING"* ]]; then
  err "Robot is not in RUNNING mode. Power on and release brakes on the pendant."; exit 1
fi
if [[ "$smode" != *"NORMAL"* ]]; then
  err "Safetymode is not NORMAL ($smode). Clear protective stop on the pendant."; exit 1
fi
if [[ "$running" == *"true"* ]]; then
  warn "A program is currently running. Stop it first (■ button) so we can start cleanly."
fi

# 4) Start ros2 launch -> PC begins listening on 50001-50003
echo
info "드라이버 시작 — 0.6초 후 pendant Play 자동 전송 시도"
echo "   (Remote Control 모드가 아닐 경우 'controller_manager: ... Hz' 뜨면 즉시 ▶ Play 클릭)"
echo

# Hardware interface가 reverse port 열기까지 ~0.5s 소요.
# 0.6s 후 play 전송 → URCap이 연결 → config package 수신 → 1초 timeout 통과
(
  sleep 0.6
  python3 -c "
import socket, time
try:
    s = socket.socket(); s.settimeout(3.0)
    s.connect(('$ROBOT_IP', 29999))
    s.recv(2048)
    s.sendall(b'play\n'); time.sleep(0.3); s.recv(2048)
    s.close()
except: pass
"
) &

exec ros2 launch ur_robot_driver ur_control.launch.py \
  ur_type:=$UR_TYPE \
  robot_ip:=$ROBOT_IP \
  reverse_ip:=$REVERSE_IP \
  launch_rviz:=false
