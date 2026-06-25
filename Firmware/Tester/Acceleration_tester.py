import time
import serial
import matplotlib.pyplot as plt
from collections import deque

# --- CONFIGURATION ---
SERIAL_PORT = "COM3"  # Replace with your actual port (e.g., "COM5" or "/dev/ttyUSB0")
BAUD_RATE = 115200
MAX_POINTS = 100  # Number of scrolling points visible on screen
OUTPUT_IMAGE = "live_g_force_profile.png"

# Scale factor: 8192.0 for +/-4G, 4096.0 for +/-8G
MPU6050_SCALE_FACTOR = 4096.0


def main():
    # Fast scrolling window data storage
    time_data = deque(maxlen=MAX_POINTS)
    accel_data = deque(maxlen=MAX_POINTS)

    # Complete session history arrays for final output graph
    all_time = []
    all_accel = []

    max_g_force = 0.0

    try:
        ser = serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=1)
        time.sleep(2)  # Wait for ESP32 stabilization
        print(f"Connected to {SERIAL_PORT}! Starting real-time G-force plot window...")
        print("--> Close the plot window or press Ctrl+C to stop and save history. <--\n")

        # Initialize Matplotlib Interactive Mode
        plt.ion()
        fig, ax = plt.subplots(figsize=(10, 5))

        # Setup telemetry drawing line
        line, = ax.plot([], [], color='#1f77b4', linewidth=2, label='Total Force (G)')

        # Setup static labels
        ax.set_title("Guac-Track: Live Bow Telemetry Profile", fontsize=12, pad=12)
        ax.set_xlabel("Time (seconds)", fontsize=10)
        ax.set_ylabel("Acceleration (G-Forces)", fontsize=10)
        ax.grid(True, linestyle='--', alpha=0.5)
        ax.legend(loc="upper left")

        start_time = time.time()

        while plt.fignum_exists(fig.number):
            if ser.in_waiting > 0:
                # --- FIX 1: BACKLOG PURGE ---
                # If the buffer gets heavily backed up, dump old data to stay in the immediate present
                if ser.in_waiting > 500:
                    ser.reset_input_buffer()
                    continue

                # --- FIX 2: CRASH-PROOF DECODING ---
                try:
                    raw_bytes = ser.readline()
                    raw_line = raw_bytes.decode('utf-8', errors='ignore').strip()

                    # --- FIX 3: EMPTY STRING GUARD ---
                    # Safely reject empty strings or fragments caused by the buffer resets
                    if not raw_line:
                        continue

                except (UnicodeDecodeError, serial.SerialException):
                    continue

                # Safe to parse the numerical float now
                try:
                    raw_total_accel = float(raw_line)
                    g_forces = raw_total_accel / MPU6050_SCALE_FACTOR

                    elapsed_time = time.time() - start_time

                    # Monitor absolute peak force recorded
                    if g_forces > max_g_force:
                        max_g_force = g_forces

                    # Update window frame arrays
                    time_data.append(elapsed_time)
                    accel_data.append(g_forces)

                    # Update final log arrays
                    all_time.append(elapsed_time)
                    all_accel.append(g_forces)

                    # Repaint tracking coordinate paths
                    line.set_data(time_data, accel_data)

                    # Adjust camera constraints smoothly
                    ax.set_xlim(time_data[0], time_data[-1] + 0.1 if len(time_data) > 1 else elapsed_time + 1)

                    if len(accel_data) > 0:
                        min_y, max_y = min(accel_data), max(accel_data)
                        padding = max((max_y - min_y) * 0.1, 0.5)  # Keep adequate breathing room
                        ax.set_ylim(min_y - padding, max_y + padding)

                    fig.canvas.draw()
                    fig.canvas.flush_events()

                    print(f"Time: {elapsed_time:6.2f}s | Current: {g_forces:5.2f} G | Peak: {max_g_force:5.2f} G",
                          end='\r')

                except ValueError:
                    pass

            time.sleep(0.001)  # Yield CPU execution cycles back to system OS

    except (KeyboardInterrupt, SystemExit):
        print("\n[!] Data stream interrupted.")

    finally:
        # Generate clean session final report plot asset
        if all_time:
            print(f"\nProcessing final historical graph ({len(all_time)} total data nodes)...")
            plt.ioff()
            plt.close(fig)

            final_fig, final_ax = plt.subplots(figsize=(12, 6))
            final_ax.plot(all_time, all_accel, color='#e377c2', linewidth=1.5, label='Shot Timeline')

            final_ax.axhline(max_g_force, color='red', linestyle=':', alpha=0.7,
                             label=f'Max Release Impact Peak: {max_g_force:.2f} G')

            final_ax.set_title('Guac-Track: Comprehensive Arrow Release Acceleration History', fontsize=12, pad=12)
            final_ax.set_xlabel('Time (seconds)', fontsize=11)
            final_ax.set_ylabel('Total Force (G-Forces)', fontsize=11)
            final_ax.grid(True, linestyle='--', alpha=0.6)
            final_ax.legend(loc="upper right")
            plt.tight_layout()

            plt.savefig(OUTPUT_IMAGE, dpi=300)
            print(f"[✓] Complete high-resolution telemetry log exported to '{OUTPUT_IMAGE}'")

        if 'ser' in locals() and ser.is_open:
            ser.close()
            print("Serial port connection closed cleanly.")


if __name__ == "__main__":
    main()