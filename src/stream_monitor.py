#!/usr/bin/env python3
"""
Claude Council — Compact in-place stream monitor.
Shows one status line per agent, updated in-place.

Usage: python3 stream_monitor.py <stream_dir> <agent1> <agent2> [agent3] ...
"""

import sys, os, time, shutil, signal

# ── Graceful exit on Ctrl+C ──
def handle_sigint(sig, frame):
    sys.stdout.write(SHOW_CURSOR)
    sys.stdout.write('\n')
    sys.stdout.flush()
    sys.exit(0)

signal.signal(signal.SIGINT, handle_sigint)

# ── ANSI ──
RESET       = '\033[0m'
BOLD        = '\033[1m'
DIM         = '\033[2m'
GREEN       = '\033[0;32m'
HIDE_CURSOR = '\033[?25l'
SHOW_CURSOR = '\033[?25h'

AGENT_STYLES = {
    'architect':     {'color': '\033[0;34m', 'icon': '🏗️',  'short': 'architect    '},
    'pragmatist':    {'color': '\033[0;32m', 'icon': '🚀',  'short': 'pragmatist   '},
    'security-perf': {'color': '\033[0;31m', 'icon': '🛡️',  'short': 'security-perf'},
}

# Maximum time to wait (seconds) before force-exiting
MAX_WAIT = 300


def is_pid_alive(pid_file):
    """Check if the process in pid_file is still running."""
    try:
        pid = int(open(pid_file).read().strip())
        os.kill(pid, 0)
        return True
    except (FileNotFoundError, ValueError, ProcessLookupError, PermissionError, OSError):
        return False


def render(agents, state, term_width):
    """
    Redraw all agent lines in-place.
    Uses \\033[F (cursor previous line) to go back, \\033[2K to clear each line.
    """
    n = len(agents)

    # Move cursor back to start of our block
    # \033[F = move to beginning of previous line (CPL)
    if not state['first_render']:
        sys.stdout.write(f'\033[{n}F')
    else:
        state['first_render'] = False

    for name in agents:
        style = AGENT_STYLES.get(name, {'color': '\033[0;35m', 'icon': '🤖', 'short': name})
        color = style['color']
        icon = style['icon']
        tc = state['tool_counts'][name]
        is_done = state['done'].get(name, False)

        # Build the status portion
        if is_done:
            if tc > 0:
                status_part = f'{GREEN}✓ done{RESET}  {DIM}({tc} tools used){RESET}'
            else:
                status_part = f'{GREEN}✓ done{RESET}'
        else:
            st = state['status'][name]
            # Truncate status to fit terminal
            max_st = max(20, term_width - 30)
            if len(st) > max_st:
                st = st[:max_st - 1] + '…'
            if tc > 0:
                status_part = f'{DIM}🔧 ×{tc}{RESET}  {st}'
            else:
                status_part = st

        # Clear line, write content
        # \033[2K = clear entire line, \r = go to column 0
        line = f'\033[2K  {color}{icon} {style["short"]}{RESET} │ {status_part}'
        sys.stdout.write(line + '\n')

    sys.stdout.flush()


def main():
    if len(sys.argv) < 3:
        print("Usage: python3 stream_monitor.py <stream_dir> <agent1> [agent2] ...")
        sys.exit(1)

    stream_dir = sys.argv[1]
    agents = sys.argv[2:]  # list of agent names in order

    term_width = shutil.get_terminal_size((80, 24)).columns

    state = {
        'first_render': True,
        'offsets': {name: 0 for name in agents},
        'status': {name: 'starting...' for name in agents},
        'tool_counts': {name: 0 for name in agents},
        'done': {name: False for name in agents},
    }

    # Hide cursor
    sys.stdout.write(HIDE_CURSOR)
    sys.stdout.flush()

    # Print initial blank lines to reserve space
    for _ in agents:
        sys.stdout.write('\n')
    sys.stdout.flush()

    start = time.time()

    try:
        while True:
            changed = False
            all_done = True

            for name in agents:
                stream_file = os.path.join(stream_dir, f'{name}.stream')
                pid_file = os.path.join(stream_dir, f'{name}.pid')

                # ── Read new stream content ──
                if os.path.exists(stream_file):
                    try:
                        size = os.path.getsize(stream_file)
                    except OSError:
                        size = 0

                    if size > state['offsets'][name]:
                        try:
                            with open(stream_file, 'r', errors='replace') as f:
                                f.seek(state['offsets'][name])
                                new_data = f.read()
                            state['offsets'][name] = size
                        except OSError:
                            new_data = ''

                        if new_data:
                            for chunk in new_data.split('\n'):
                                chunk = chunk.strip()
                                if not chunk or '━━━ done ━━━' in chunk:
                                    continue
                                if chunk.startswith('🔧 [using '):
                                    tool_name = chunk.replace('🔧 [using ', '').rstrip('.]')
                                    state['tool_counts'][name] += 1
                                    state['status'][name] = f'using {tool_name}...'
                                    changed = True
                                else:
                                    # Show the latest text, cleaned up
                                    clean = chunk.replace('\r', '').strip()
                                    if clean:
                                        state['status'][name] = clean
                                        changed = True

                # ── Check if agent is still running ──
                if not state['done'][name]:
                    if os.path.exists(pid_file):
                        if is_pid_alive(pid_file):
                            all_done = False
                        else:
                            state['done'][name] = True
                            changed = True
                    else:
                        all_done = False  # PID file not yet created

            if changed:
                render(agents, state, term_width)

            if all_done:
                # One final render to show all as done
                time.sleep(0.3)
                render(agents, state, term_width)
                break

            # Timeout safety
            if time.time() - start > MAX_WAIT:
                for name in agents:
                    if not state['done'][name]:
                        state['status'][name] = 'timed out'
                        state['done'][name] = True
                render(agents, state, term_width)
                break

            time.sleep(0.15)

    finally:
        sys.stdout.write(SHOW_CURSOR)
        sys.stdout.write('\n')
        sys.stdout.flush()


if __name__ == '__main__':
    main()
