import time
import serial
import matplotlib.pyplot as plt
from collections import deque

# --- CONFIGURATION ---
SERIAL_PORT = "COM3"  # Update to match your actual port
BAUD_RATE = 115200
MAX_POINTS = 100      # Visible window points
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
    clicker_events = []  # Stores timestamps of all detected clicks

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

        # Track active vertical lines on the scrolling canvas
        active_vlines = []
        start_time = time.time()

        while plt.fignum_exists(fig.number):
            if ser.in_waiting > 0:
                # Purge old buffer data if backed up
                if ser.in_waiting > 500:
                    ser.reset_input_buffer()
                    continue

                try:
                    raw_bytes = ser.readline()
                    raw_line = raw_bytes.decode('utf-8', errors='ignore').strip()

                    if not raw_line:
                        continue

                except (UnicodeDecodeError, serial.SerialException):
                    continue

                # Parse the incoming packet: "accel_magnitude,clicker_state" or fallback to single float
                try:
                    parts = raw_line.split(',')
                    if len(parts) >= 2:
                        raw_total_accel = float(parts[0])
                        clicker_state = int(parts[1])
                    else:
                        raw_total_accel = float(parts[0])
                        clicker_state = 0

                    g_forces = raw_total_accel / MPU6050_SCALE_FACTOR
                    elapsed_time = time.time() - start_time

                    if g_forces > max_g_force:
                        max_g_force = g_forces

                    # Update history queues
                    time_data.append(elapsed_time)
                    accel_data.append(g_forces)

                    all_time.append(elapsed_time)
                    all_accel.append(g_forces)

                    # Update live line path
                    line.set_data(time_data, accel_data)

                    # Adjust X-axis scrolling window
                    window_start = time_data[0]
                    window_end = time_data[-1] + 0.1 if len(time_data) > 1 else elapsed_time + 1
                    ax.set_xlim(window_start, window_end)

                    # Dynamic Y-axis scaling
                    if len(accel_data) > 0:
                        min_y, max_y = min(accel_data), max(accel_data)
                        padding = max((max_y - min_y) * 0.1, 0.5)
                        ax.set_ylim(min_y - padding, max_y + padding)

                    # Handle clicker detection event
                    if clicker_state == 1:
                        clicker_events.append(elapsed_time)
                        # Draw live gold marker line
                        vline = ax.axvline(x=elapsed_time, color='gold', linestyle='--', linewidth=2)
                        active_vlines.append((elapsed_time, vline))

                    # Remove out-of-frame vertical lines to prevent memory buildup
                    for t_event, line_obj in list(active_vlines):
                        if t_event < window_start:
                            line_obj.remove()
                            active_vlines.remove((t_event, line_obj))

                    fig.canvas.draw()
                    fig.canvas.flush_events()

                    status_tag = " [CLICK!]" if clicker_state == 1 else ""
                    print(f"Time: {elapsed_time:6.2f}s | Current: {g_forces:5.2f} G | Peak: {max_g_force:5.2f} G{status_tag}   ",
                          end='\r')

                except ValueError:
                    pass

            time.sleep(0.001)

    except (KeyboardInterrupt, SystemExit):
        print("\n[!] Data stream interrupted.")

    finally:
        # Generate session export plot with all telemetry and clicker markers
        if all_time:
            print(f"\nProcessing final historical graph ({len(all_time)} data points, {len(clicker_events)} clicks)...")
            plt.ioff()
            plt.close(fig)

            final_fig, final_ax = plt.subplots(figsize=(12, 6))
            final_ax.plot(all_time, all_accel, color='#1f77b4', linewidth=1.5, label='Acceleration Profile')

            # Render persistent markers for all clicker timestamps
            for i, click_time in enumerate(clicker_events):
                final_ax.axvline(
                    x=click_time,
                    color='gold',
                    linestyle='--',
                    linewidth=2,
                    label='Clicker Event' if i == 0 else ""
                )

            final_ax.axhline(max_g_force, color='red', linestyle=':', alpha=0.7,
                             label=f'Max Peak: {max_g_force:.2f} G')

            final_ax.set_title('Guac-Track: Comprehensive Arrow Release & Clicker Profile', fontsize=12, pad=12)
            final_ax.set_xlabel('Time (seconds)', fontsize=11)
            final_ax.set_ylabel('Total Force (G-Forces)', fontsize=11)
            final_ax.grid(True, linestyle='--', alpha=0.6)
            final_ax.legend(loc="upper right")
            plt.tight_layout()

            plt.savefig(OUTPUT_IMAGE, dpi=300)
            print(f"[✓] Final telemetry log exported to '{OUTPUT_IMAGE}'")

        if 'ser' in locals() and ser.is_open:
            ser.close()
            print("Serial port connection closed cleanly.")


if __name__ == "__main__":
    main()