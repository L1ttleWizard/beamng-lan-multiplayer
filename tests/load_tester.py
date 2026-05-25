import socket
import time
import json
import struct
import math
import argparse
import random

def main():
    parser = argparse.ArgumentParser(description="BeamNG LAN Multiplayer Load Tester Client")
    parser.add_argument("--ip", type=str, default="127.0.0.1", help="Target server IP")
    parser.add_argument("--port", type=int, default=27015, help="Target server port")
    parser.add_argument("--bind-ip", type=str, default=None, help="Local IP to bind the client socket to")
    parser.add_argument("--bind-port", type=int, default=None, help="Local port to bind the client socket to")
    parser.add_argument("--rate", type=int, default=60, help="Send rate in Hz")
    parser.add_argument("--radius", type=float, default=20.0, help="Trajectory circle radius")
    parser.add_argument("--speed", type=float, default=15.0, help="Simulated speed (m/s)")
    parser.add_argument("--center", type=str, default=None, help="Manual center position as 'x,y,z'")
    parser.add_argument("--no-handshake", action="store_true", help="Skip sending connection handshake and start telemetry stream directly")
    parser.add_argument("--json", action="store_true", help="Transmit circular telemetry encoded as JSON string packets instead of binary")
    args = parser.parse_args()

    client_id = random.randint(1000, 9999)
    nickname = f"LoadTester_{client_id}"
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if args.bind_port is not None:
        bind_ip = args.bind_ip or "0.0.0.0"
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((bind_ip, args.bind_port))
            print(f"[{nickname}] Bound local socket to {bind_ip}:{args.bind_port}")
        except Exception as e:
            print(f"[{nickname}] Failed to bind local socket to {bind_ip}:{args.bind_port}: {e}")
    server_addr = (args.ip, args.port)

    center_x = 0.0
    center_y = 0.0
    center_z = 0.0

    if args.center:
        try:
            parts = args.center.split(',')
            center_x = float(parts[0])
            center_y = float(parts[1])
            center_z = float(parts[2])
            print(f"[{nickname}] Using manual trajectory center: ({center_x}, {center_y}, {center_z})")
        except Exception as e:
            print(f"[{nickname}] Failed to parse manual center '{args.center}': {e}. Using automatic discovery.")

    if not args.no_handshake:
        # 1. Send connection handshake
        handshake = {
            "type": "connect",
            "nickname": nickname,
            "model": "covet",
            "config": {"parts": {}, "vars": {}},
            "pos": {"x": center_x, "y": center_y, "z": center_z},
            "rot": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0}
        }
        
        # Send connection handshake with retries
        connected = False
        sock.settimeout(0.5)
        max_retries = 30
        
        print(f"[{nickname}] Connecting to {args.ip}:{args.port}...")
        for attempt in range(max_retries):
            try:
                sock.sendto(json.dumps(handshake).encode('utf-8'), server_addr)
                
                # If manual center not provided, discover it from connect_ack
                data, addr = sock.recvfrom(4096)
                response = json.loads(data.decode('utf-8'))
                if response.get("type") == "connect_ack":
                    if not args.center and "pos" in response:
                        pos = response["pos"]
                        center_x = float(pos.get("x", 0.0))
                        center_y = float(pos.get("y", 0.0))
                        center_z = float(pos.get("z", 0.0))
                    print(f"[{nickname}] Connected! Discovered host position: ({center_x}, {center_y}, {center_z})")
                    connected = True
                    break
            except socket.timeout:
                continue
            except Exception as e:
                # Under Windows, WinError 10054 happens if port is not yet open
                time.sleep(0.5)
                continue
                
        if not connected:
            print(f"[{nickname}] Failed to receive connect_ack. Starting telemetry stream anyway.")
        
        sock.settimeout(None)

    # 2. Main loop: Send binary DPUB packets simulating a circular driving path
    seq = 0
    start_time = time.time()
    send_interval = 1.0 / args.rate
    
    # DPUB format string: magic, seq, px, py, pz, rx, ry, rz, rw, vx, vy, vz, ax, ay, az, throttle, steering, brake, clutch, handbrake, rpm, wheelSpeed, gear, lights, flags
    pack_format = "<IIffffffffffffffffffffhBB"
    magic = 0x42555044 # "DPUB"

    print(f"[{nickname}] Starting telemetry stream at {args.rate} Hz...")
    try:
        while True:
            current_time = time.time()
            elapsed = current_time - start_time
            
            # Calculate circular motion
            angular_velocity = args.speed / args.radius
            angle = elapsed * angular_velocity
            
            px = center_x + args.radius * math.cos(angle)
            py = center_y + args.radius * math.sin(angle)
            pz = center_z + 0.5 # slightly above center_z
            
            # Face the direction of velocity (tangent to circle)
            yaw = angle
            # Quaternion from yaw (Z axis rotation)
            rx = 0.0
            ry = 0.0
            rz = math.sin(yaw / 2.0)
            rw = math.cos(yaw / 2.0)
            
            vx = -args.speed * math.sin(angle)
            vy = args.speed * math.cos(angle)
            vz = 0.0
            
            ax, ay, az = 0.0, 0.0, angular_velocity
            
            throttle = 0.8
            steering = math.sin(elapsed) * 0.25 # slight wobble
            brake = 0.0
            clutch = 0.0
            handbrake = 0.0
            
            rpm = 3000.0 + 1000.0 * math.sin(elapsed)
            wheel_speed = args.speed
            gear = 3
            lights = 1 # low beams
            flags = 0 # standard
            
            if args.json:
                # Pack JSON packet matching short format 't' == 'u'
                payload = {
                    "t": "u",
                    "s": seq,
                    "p": [px, py, pz],
                    "r": [rx, ry, rz, rw],
                    "v": [vx, vy, vz],
                    "a": [ax, ay, az],
                    "i": [throttle, steering, brake, clutch, handbrake],
                    "rpm": rpm,
                    "wheelSpeed": wheel_speed,
                    "gear": gear,
                    "lights": lights,
                    "flags": flags
                }
                packet_data = json.dumps(payload).encode('utf-8')
            else:
                # Pack binary packet
                packet_data = struct.pack(
                    pack_format,
                    magic, seq,
                    px, py, pz,
                    rx, ry, rz, rw,
                    vx, vy, vz,
                    ax, ay, az,
                    throttle, steering, brake, clutch, handbrake,
                    rpm, wheel_speed,
                    gear, lights, flags
                )
            
            sock.sendto(packet_data, server_addr)
            seq += 1
            
            # Sleep to match Hz rate
            next_send = current_time + send_interval
            sleep_time = next_send - time.time()
            if sleep_time > 0:
                time.sleep(sleep_time)
                
    except KeyboardInterrupt:
        print(f"\n[{nickname}] Terminating load test.")

if __name__ == "__main__":
    main()
