#!/usr/bin/env python3
"""
Claude Council — Interactive terminal results viewer.
Called by council.sh after deliberation completes.

Usage: python3 results_viewer.py <session_dir>
"""

import sys, os, json, textwrap, shutil, re

# ── ANSI codes ──
RESET  = "\033[0m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
ITALIC = "\033[3m"
RED    = "\033[0;31m"
GREEN  = "\033[0;32m"
YELLOW = "\033[1;33m"
BLUE   = "\033[0;34m"
PURPLE = "\033[0;35m"
CYAN   = "\033[0;36m"
WHITE  = "\033[1;37m"
BG_DARK = "\033[48;5;236m"

AGENT_STYLES = {
    "architect":     {"color": BLUE,  "icon": "🏗️ ", "label": "Architect"},
    "pragmatist":    {"color": GREEN, "icon": "🚀", "label": "Pragmatist"},
    "security-perf": {"color": RED,   "icon": "🛡️ ", "label": "Security & Perf"},
}

def render_md(text):
    """Convert markdown formatting to ANSI terminal codes."""
    if not text:
        return text
    s = str(text)
    # Fenced code blocks: ```...\n```  →  dim + indented
    def _code_block(m):
        code = m.group(2).rstrip('\n')
        lines = code.split('\n')
        rendered = '\n'.join(f"    {DIM}{line}{RESET}" for line in lines)
        return f"\n{rendered}\n"
    s = re.sub(r'```\w*\n([\s\S]*?)```', _code_block, s)
    # Inline code: `code` → cyan
    s = re.sub(r'`([^`\n]+)`', f'{CYAN}\\1{RESET}', s)
    # Bold: **text** → ANSI bold
    s = re.sub(r'\*\*([^*]+)\*\*', f'{BOLD}\\1{RESET}', s)
    # Italic: *text* → ANSI italic
    s = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', f'{ITALIC}\\1{RESET}', s)
    return s

def get_term_width():
    return shutil.get_terminal_size((80, 24)).columns

def wrap(text, indent=4, width=None):
    if width is None:
        width = min(get_term_width() - indent - 2, 100)
    prefix = " " * indent
    lines = textwrap.wrap(str(text), width=width)
    return "\n".join(prefix + line for line in lines)

def hr(char="─", width=None):
    if width is None:
        width = min(get_term_width() - 2, 80)
    return f"  {DIM}{char * width}{RESET}"

def confidence_bar(value, width=20):
    """Render a colored bar: ████████░░░░ 85%"""
    if isinstance(value, str):
        try:
            value = float(value)
        except:
            return f"{DIM}N/A{RESET}"
    pct = int(value * 100) if value <= 1.0 else int(value)
    filled = int(pct / 100 * width)
    empty = width - filled
    if pct >= 80:
        color = GREEN
    elif pct >= 60:
        color = YELLOW
    else:
        color = RED
    return f"{color}{'█' * filled}{DIM}{'░' * empty}{RESET} {pct}%"

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except:
        return {}

def format_opinion_compact(name, opinion):
    """One-liner summary for the menu view."""
    style = AGENT_STYLES.get(name, {"color": PURPLE, "icon": "🤖", "label": name})
    rec = opinion.get("recommendation", "No recommendation")
    if len(rec) > 90:
        rec = rec[:87] + "..."
    conf = opinion.get("confidence", "?")
    conf_str = confidence_bar(conf, 12) if isinstance(conf, (int, float)) else f"{DIM}{conf}{RESET}"
    return f"  {style['color']}{style['icon']} {style['label']:<16}{RESET} {conf_str}  {render_md(rec)}"

def format_opinion_full(name, opinion):
    """Full expanded view of an agent's opinion."""
    style = AGENT_STYLES.get(name, {"color": PURPLE, "icon": "🤖", "label": name})
    c = style["color"]
    lines = []

    lines.append("")
    lines.append(f"  {c}{BOLD}{style['icon']} {style['label']}{RESET}")
    lines.append(hr("━"))

    # Recommendation
    rec = opinion.get("recommendation", "No recommendation provided")
    lines.append(f"\n  {BOLD}Recommendation{RESET}")
    lines.append(wrap(render_md(rec)))

    # Confidence
    conf = opinion.get("confidence")
    if conf is not None:
        lines.append(f"\n  {BOLD}Confidence{RESET}")
        lines.append(f"    {confidence_bar(conf)}")

    # Reasoning
    reasoning = opinion.get("reasoning", [])
    if reasoning:
        lines.append(f"\n  {BOLD}Reasoning{RESET}")
        for i, r in enumerate(reasoning, 1):
            lines.append(f"    {DIM}{i}.{RESET} {render_md(r)}")

    # Tradeoffs
    tradeoffs = opinion.get("tradeoffs", {})
    pros = tradeoffs.get("pros", [])
    cons = tradeoffs.get("cons", [])
    if pros or cons:
        lines.append(f"\n  {BOLD}Tradeoffs{RESET}")
        if pros:
            for p in pros:
                lines.append(f"    {GREEN}+{RESET} {render_md(p)}")
        if cons:
            for c_item in cons:
                lines.append(f"    {RED}−{RESET} {render_md(c_item)}")

    # Assumptions
    assumptions = opinion.get("assumptions", [])
    if assumptions:
        lines.append(f"\n  {BOLD}Assumptions{RESET}")
        for a in assumptions:
            lines.append(f"    {DIM}•{RESET} {render_md(a)}")

    # Codebase evidence
    evidence = opinion.get("codebase_evidence", [])
    if evidence:
        lines.append(f"\n  {BOLD}Codebase Evidence{RESET}")
        for e in evidence:
            lines.append(f"    {CYAN}→{RESET} {render_md(e)}")

    # Belief triggers
    triggers = opinion.get("belief_triggers", [])
    if triggers:
        lines.append(f"\n  {BOLD}Belief Triggers{RESET}")
        for t in triggers:
            lines.append(f"    {YELLOW}⚡{RESET} {render_md(t)}")

    lines.append("")
    lines.append(hr())
    return "\n".join(lines)

def format_verdict(synthesis):
    """Format the synthesis/verdict."""
    lines = []
    lines.append("")
    lines.append(f"  {BOLD}{WHITE}⚖️  COUNCIL VERDICT{RESET}")
    lines.append(hr("━"))

    verdict = synthesis.get("verdict", "No verdict rendered")
    lines.append(f"\n  {BOLD}Decision{RESET}")
    lines.append(wrap(render_md(verdict)))

    # Confidence scores
    scores = synthesis.get("confidence_scores", {})
    if scores:
        lines.append(f"\n  {BOLD}Confidence{RESET}")
        for agent, score in scores.items():
            style = AGENT_STYLES.get(agent, {"icon": " ", "label": agent, "color": ""})
            label = style.get("label", agent)
            bar = confidence_bar(score)
            if agent == "overall":
                lines.append(f"    {BOLD}{'Overall':<16}{RESET} {bar}")
            else:
                lines.append(f"    {style['color']}{label:<16}{RESET} {bar}")

    # Consensus
    consensus = synthesis.get("consensus", [])
    if consensus:
        lines.append(f"\n  {GREEN}{BOLD}Consensus{RESET}")
        for c in consensus:
            point = c.get("point", c) if isinstance(c, dict) else c
            strength = c.get("strength", "") if isinstance(c, dict) else ""
            agents_list = c.get("agents", []) if isinstance(c, dict) else []
            lines.append(f"    {GREEN}✓{RESET} {render_md(point)}")
            if strength or agents_list:
                meta = []
                if strength:
                    meta.append(strength)
                if agents_list:
                    meta.append(", ".join(agents_list))
                lines.append(f"      {DIM}{' · '.join(meta)}{RESET}")

    # Divergence
    divergence = synthesis.get("divergence", [])
    if divergence:
        lines.append(f"\n  {YELLOW}{BOLD}Divergence{RESET}")
        for d in divergence:
            point = d.get("point", d) if isinstance(d, dict) else d
            lines.append(f"    {YELLOW}⚡{RESET} {render_md(point)}")
            positions = d.get("positions", {}) if isinstance(d, dict) else {}
            for agent, pos in positions.items():
                style = AGENT_STYLES.get(agent, {"color": PURPLE, "label": agent})
                lines.append(f"      {style['color']}{style['label']}{RESET}: {render_md(pos)}")
            resolution = d.get("resolution", "") if isinstance(d, dict) else ""
            if resolution:
                lines.append(f"      {CYAN}{ITALIC}Resolution: {render_md(resolution)}{RESET}")

    # Action items — supports string[], {priority,action}[], and full structured format
    actions = synthesis.get("action_items", [])
    if actions:
        is_structured = actions and isinstance(actions[0], dict) and "priority" in actions[0]
        if is_structured:
            prio_colors = {"high": RED, "medium": YELLOW, "low": GREEN}
            prio_icons  = {"high": "🔴", "medium": "🟡", "low": "🟢"}
            type_icons  = {"action": "⚡", "note": "📝"}
            groups = {"high": [], "medium": [], "low": []}
            for a in actions:
                p = a.get("priority", "low")
                groups.setdefault(p, []).append(a)
            for prio in ["high", "medium", "low"]:
                items = groups.get(prio, [])
                if not items:
                    continue
                color = prio_colors.get(prio, "")
                icon = prio_icons.get(prio, "")
                label = prio.capitalize()
                lines.append(f"\n  {color}{BOLD}{icon} {label} Priority{RESET}")
                for i, item in enumerate(items, 1):
                    item_type = item.get("type", "action")
                    ti = type_icons.get(item_type, "•")
                    type_label = f"{DIM}[{item_type}]{RESET} " if item_type == "note" else ""
                    lines.append(f"    {BOLD}{i}.{RESET} {ti} {type_label}{render_md(item.get('action', ''))}")
                    # Show AI prompt hint if available
                    if item.get("ai_prompt"):
                        lines.append(f"       {DIM}💬 AI prompt available (see HTML viewer to copy){RESET}")
        else:
            lines.append(f"\n  {BOLD}Action Items{RESET}")
            for i, a in enumerate(actions, 1):
                text = a if isinstance(a, str) else a.get("action", str(a))
                lines.append(f"    {BOLD}{i}.{RESET} {render_md(text)}")

    # Revisit triggers
    triggers = synthesis.get("revisit_triggers", [])
    if triggers:
        lines.append(f"\n  {BOLD}Revisit When{RESET}")
        for t in triggers:
            lines.append(f"    {DIM}🔄{RESET} {render_md(t)}")

    lines.append("")
    lines.append(hr())
    return "\n".join(lines)


def interactive_browser(session_dir, opinions, synthesis):
    """Interactive menu to browse results."""
    import tty, termios

    agent_names = list(opinions.keys())

    def read_key():
        """Read a single keypress."""
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            ch = sys.stdin.read(1)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        return ch

    def show_menu():
        print()
        print(f"  {BOLD}Council Results — Press a key to expand{RESET}")
        print(hr("─"))
        print()

        for i, name in enumerate(agent_names):
            opinion = opinions[name]
            num = f"{BOLD}{i + 1}{RESET}"
            print(f"  {num}  {format_opinion_compact(name, opinion)}")

        print()
        print(f"  {BOLD}v{RESET}  {WHITE}⚖️  View full verdict{RESET}")
        print(f"  {BOLD}a{RESET}  {WHITE}📋  View all (expand everything){RESET}")
        print(f"  {BOLD}o{RESET}  {WHITE}🌐  Open HTML viewer in browser{RESET}")
        print(f"  {BOLD}q{RESET}  {DIM}    Continue to follow-up →{RESET}")
        print()
        sys.stdout.write(f"  {DIM}▸ Press a key...{RESET}")
        sys.stdout.flush()

    while True:
        show_menu()

        key = read_key()
        # Clear the "Press a key..." prompt
        sys.stdout.write("\r\033[2K")

        if key == "q" or key == "\x03":  # q or Ctrl+C
            print()
            break

        elif key == "v":
            print(format_verdict(synthesis))
            print(f"\n  {DIM}Press any key to return...{RESET}")
            read_key()

        elif key == "a":
            # Show everything
            for name in agent_names:
                print(format_opinion_full(name, opinions[name]))
            print(format_verdict(synthesis))
            print(f"\n  {DIM}Press any key to return...{RESET}")
            read_key()

        elif key == "o":
            viewer_path = os.path.join(session_dir, "viewer.html")
            if os.path.exists(viewer_path):
                os.system(f'open "{viewer_path}" 2>/dev/null || xdg-open "{viewer_path}" 2>/dev/null')
                print(f"\n  {GREEN}Opened viewer in browser{RESET}")
            else:
                print(f"\n  {RED}Viewer not found{RESET}")
            import time; time.sleep(0.8)

        elif key.isdigit():
            idx = int(key) - 1
            if 0 <= idx < len(agent_names):
                name = agent_names[idx]
                print(format_opinion_full(name, opinions[name]))
                print(f"\n  {DIM}Press any key to return...{RESET}")
                read_key()


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 results_viewer.py <session_dir>")
        sys.exit(1)

    session_dir = sys.argv[1]

    # Load opinions
    opinions = {}
    stage1_dir = os.path.join(session_dir, "stage1")
    if os.path.isdir(stage1_dir):
        for f in sorted(os.listdir(stage1_dir)):
            if f.startswith("opinion_") and f.endswith(".json"):
                name = f.replace("opinion_", "").replace(".json", "")
                opinions[name] = load_json(os.path.join(stage1_dir, f))

    # Load synthesis
    synthesis = load_json(os.path.join(session_dir, "synthesis.json"))

    # ── Print the quick verdict summary first ──
    print()
    print(f"  {BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{RESET}")
    print(f"  {BOLD}              ⚖️  COUNCIL VERDICT{RESET}")
    print(f"  {BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{RESET}")
    print()

    verdict = synthesis.get("verdict", "No verdict rendered")
    overall = synthesis.get("confidence_scores", {}).get("overall", "N/A")
    print(f"  {GREEN}{BOLD}{render_md(verdict)}{RESET}")
    print()
    if overall != "N/A":
        print(f"  {BOLD}Confidence:{RESET} {confidence_bar(overall)}")
    print()

    # Quick action items — priority-aware with type labels
    actions = synthesis.get("action_items", [])
    if actions:
        is_structured = actions and isinstance(actions[0], dict) and "priority" in actions[0]
        if is_structured:
            prio_icons = {"high": "🔴", "medium": "🟡", "low": "🟢"}
            prio_colors = {"high": RED, "medium": YELLOW, "low": GREEN}
            type_icons = {"action": "⚡", "note": "📝"}
            for prio in ["high", "medium", "low"]:
                items = [a for a in actions if a.get("priority") == prio]
                if not items:
                    continue
                label = prio.capitalize()
                print(f"  {prio_colors.get(prio, '')}{BOLD}{prio_icons.get(prio, '')} {label}:{RESET}")
                for i, a in enumerate(items, 1):
                    item_type = a.get("type", "action")
                    ti = type_icons.get(item_type, "•")
                    print(f"    {i}. {ti} {render_md(a.get('action', ''))}")
            print()
        else:
            print(f"  {BOLD}Next Steps:{RESET}")
            for i, a in enumerate(actions, 1):
                text = a if isinstance(a, str) else a.get("action", str(a))
                print(f"    {i}. {render_md(text)}")
            print()

    meta = load_json(os.path.join(session_dir, "meta.json"))
    session_id = meta.get("id", "unknown")
    elapsed = meta.get("elapsed_display", "")
    print(f"  {DIM}Session: {session_id}{elapsed and f'  ⏱️  {elapsed}' or ''}{RESET}")
    print(f"  {DIM}Viewer:  {session_dir}/viewer.html{RESET}")
    print()

    # Update meta status
    meta["status"] = "completed"
    with open(os.path.join(session_dir, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

    # ── Interactive browser ──
    if sys.stdin.isatty():
        interactive_browser(session_dir, opinions, synthesis)
    else:
        # Non-interactive: just print everything
        for name in opinions:
            print(format_opinion_full(name, opinions[name]))
        print(format_verdict(synthesis))


if __name__ == "__main__":
    main()
