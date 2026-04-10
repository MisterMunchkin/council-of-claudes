#!/usr/bin/env python3
"""
Claude Council — Interactive session prep TUI (built with Textual).

A polished terminal UI for preparing council deliberation questions,
styled after Claude Code's minimal dark aesthetic.

Features:
  - Shift+Enter for multiline input, Enter to send
  - Auto-collapsed multi-line paste ([Pasted text #N +X lines])
  - Live streaming chairman responses (token-by-token)
  - Slash commands handled locally (never sent to chairman)
  - Flag toggles for review, nexus, quick, no-stream

Usage: python3 session_prep.py [--model MODEL] [--allowed-tools TOOLS] [--mcp-config PATH]
"""

import sys
import os
import json
import asyncio

from rich.markup import escape as rich_escape
from textual import work, on, events
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, Horizontal
from textual.widgets import Header, Footer, Static, RichLog, TextArea
from textual.message import Message
from textual.reactive import reactive

# ═══════════════════════════════════════════════════════════════════════
# Constants & config
# ═══════════════════════════════════════════════════════════════════════

PASTE_LINE_THRESHOLD = 4
PASTE_CHAR_THRESHOLD = 500

MODEL = "claude-opus-4-6"
ALLOWED_TOOLS = ""
MCP_CONFIG = ""

FLAGS = {
    "review": False,
    "nexus": False,
    "quick": False,
    "no_stream": False,
}

_pasted_contents = {}
_next_paste_id = 1


def parse_args():
    global MODEL, ALLOWED_TOOLS, MCP_CONFIG
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--model" and i + 1 < len(args):
            MODEL = args[i + 1]; i += 2
        elif args[i] == "--allowed-tools" and i + 1 < len(args):
            ALLOWED_TOOLS = args[i + 1]; i += 2
        elif args[i] == "--mcp-config" and i + 1 < len(args):
            MCP_CONFIG = args[i + 1]; i += 2
        else:
            i += 1


# ═══════════════════════════════════════════════════════════════════════
# Chairman API calls
# ═══════════════════════════════════════════════════════════════════════

SYSTEM_PROMPT = (
    "You are the Chairman of a council preparing for deliberation. "
    "Your job is to help the user refine their question before it goes to the full council. "
    "Ask clarifying questions if the question is vague. "
    "Help them think about what aspects matter most. "
    "Keep responses concise (2-4 sentences). "
    "Do NOT output JSON — respond in plain conversational text. "
    "If the question is already clear and specific, say so and suggest they run /run to start the council."
)


async def call_chairman_streaming(prompt_text, on_token=None, on_done=None):
    """Call chairman via claude -p with streaming. Calls on_token(str) for each chunk."""
    cmd = [
        "claude", "-p", prompt_text,
        "--model", MODEL,
        "--output-format", "stream-json",
    ]
    if ALLOWED_TOOLS:
        cmd += ["--allowedTools", ALLOWED_TOOLS]
    if MCP_CONFIG and os.path.exists(MCP_CONFIG):
        cmd += ["--mcp-config", MCP_CONFIG]
    cmd += ["--append-system-prompt", SYSTEM_PROMPT]

    full_response = ""

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    async for line in proc.stdout:
        line = line.decode("utf-8", errors="replace").strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        etype = event.get("type", "")

        if etype == "content_block_delta":
            text = event.get("delta", {}).get("text", "")
            if text:
                full_response += text
                if on_token:
                    on_token(text)

        elif etype == "result":
            result_text = event.get("result", "")
            if result_text and not full_response:
                full_response = result_text
                if on_token:
                    on_token(result_text)

    await proc.wait()

    if on_done:
        on_done(full_response)

    return full_response


async def call_chairman_sync(prompt_text):
    """Non-streaming fallback."""
    cmd = [
        "claude", "-p", prompt_text,
        "--model", MODEL,
        "--output-format", "json",
    ]
    if ALLOWED_TOOLS:
        cmd += ["--allowedTools", ALLOWED_TOOLS]
    if MCP_CONFIG and os.path.exists(MCP_CONFIG):
        cmd += ["--mcp-config", MCP_CONFIG]
    cmd += ["--append-system-prompt", SYSTEM_PROMPT]

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, _ = await proc.communicate()
    try:
        data = json.loads(stdout.decode())
        return data.get("result", stdout.decode().strip())
    except json.JSONDecodeError:
        return stdout.decode().strip() or None


# ═══════════════════════════════════════════════════════════════════════
# Custom Input widget — multiline input matching Claude Code's approach
#
# Enter         → submit
# Newline keys  → insert newline:
#   \ + Enter   → universal (all terminals)
#   Ctrl+J      → universal (line feed character)
#   Shift+Enter → iTerm2, WezTerm, Ghostty, Kitty
#   Paste        → multi-line paste handled natively by TextArea
# ═══════════════════════════════════════════════════════════════════════

class PromptInput(TextArea):
    """A TextArea that submits on Enter, with multiple newline methods."""

    class Submitted(Message):
        """Posted when the user presses Enter to submit."""
        def __init__(self, value: str) -> None:
            super().__init__()
            self.value = value

    DEFAULT_CSS = """
    PromptInput {
        height: auto;
        max-height: 8;
        min-height: 3;
    }
    """

    def __init__(self, **kwargs):
        super().__init__(
            language=None,
            show_line_numbers=False,
            tab_behavior="focus",
            **kwargs,
        )
        self._backslash_pending = False

    async def _on_key(self, event: events.Key) -> None:
        # ── Backslash + Enter → newline (universal method) ──
        # If the last character typed was \, treat Enter as newline
        if event.key == "enter" and self._backslash_pending:
            self._backslash_pending = False
            event.stop()
            event.prevent_default()
            # Remove the trailing backslash, then insert newline
            start, end = self.selection
            row, col = start
            if col > 0:
                bs_start = (row, col - 1)
                self.replace("\n", bs_start, start)
            else:
                self._replace_via_keyboard("\n", start, end)
            return

        # Track backslash state
        if event.character == "\\":
            self._backslash_pending = True
        elif event.key != "shift":
            # Reset on any non-shift key that isn't backslash
            self._backslash_pending = False

        # ── Ctrl+J → newline (universal line feed) ──
        if event.key == "ctrl+j":
            event.stop()
            event.prevent_default()
            start, end = self.selection
            self._replace_via_keyboard("\n", start, end)
            return

        # ── Shift+Enter → newline (iTerm2, WezTerm, Ghostty, Kitty) ──
        if event.key == "shift+enter":
            event.stop()
            event.prevent_default()
            start, end = self.selection
            self._replace_via_keyboard("\n", start, end)
            return

        # ── Plain Enter → submit ──
        if event.key == "enter":
            event.stop()
            event.prevent_default()
            value = self.text.strip()
            if value:
                self.post_message(self.Submitted(value))
                self.clear()
            return

        # Everything else (typing, paste, arrows, etc.) → default
        await super()._on_key(event)


# ═══════════════════════════════════════════════════════════════════════
# The Textual App — Claude Code-inspired styling
# ═══════════════════════════════════════════════════════════════════════

HELP_TEXT = """\
[bold white]Commands[/bold white]
  [#af87ff]/run[/#af87ff]          Launch the council with the current question
  [#af87ff]/question[/#af87ff]     Show the current refined question
  [#af87ff]/edit[/#af87ff]         Re-enter the question from scratch
  [#af87ff]/quit[/#af87ff]         Exit without running the council

[bold white]Session Flags[/bold white] [dim](toggle on/off)[/dim]
  [#af87ff]/review[/#af87ff]       Peer review stage
  [#af87ff]/nexus[/#af87ff]        GitNexus integration
  [#af87ff]/quick[/#af87ff]        Skip optional stages
  [#af87ff]/no-stream[/#af87ff]    Disable live streaming
  [#af87ff]/flags[/#af87ff]        Show current flag status

[bold white]Multiline Input[/bold white]
  [dim]\\+Enter[/dim]      New line [dim](all terminals)[/dim]
  [dim]Ctrl+J[/dim]        New line [dim](all terminals)[/dim]
  [dim]Shift+Enter[/dim]   New line [dim](iTerm2, WezTerm, Ghostty, Kitty)[/dim]
  [dim]Paste[/dim]          Multi-line paste works directly

[bold white]Keys[/bold white]
  [dim]Enter[/dim]          Send message
  [dim]Ctrl+R[/dim]        Run council
  [dim]Ctrl+Q[/dim]        Quit"""


class SessionPrepApp(App):
    """Claude Council interactive session prep — Claude Code style."""

    TITLE = "Claude Council"
    CSS = """
    Screen {
        background: #1a1b26;
        layout: vertical;
    }

    /* ── Top bar ── */
    #top-bar {
        dock: top;
        height: 1;
        background: #16161e;
        color: #565f89;
        padding: 0 1;
    }

    /* ── Chat area ── */
    #chat-area {
        height: 1fr;
        padding: 0 1;
        background: #1a1b26;
    }

    #chat-log {
        height: 1fr;
        background: #1a1b26;
        padding: 0 1;
        scrollbar-size: 1 1;
        scrollbar-color: #3b4261;
        scrollbar-color-hover: #565f89;
        scrollbar-color-active: #7aa2f7;
    }

    /* ── Input area ── */
    #input-area {
        dock: bottom;
        height: auto;
        max-height: 12;
        background: #1a1b26;
        padding: 0 1 1 1;
    }

    #prompt-indicator {
        width: 3;
        height: 1;
        color: #7aa2f7;
        background: #1a1b26;
        padding: 0;
        margin: 0;
        content-align: left middle;
    }

    #input-row {
        height: auto;
        max-height: 10;
        background: #1a1b26;
    }

    PromptInput {
        background: #24283b;
        color: #c0caf5;
        border: tall #3b4261;
        height: auto;
        min-height: 3;
        max-height: 8;
        width: 1fr;
        padding: 0 1;
    }

    PromptInput:focus {
        border: tall #7aa2f7;
    }

    /* ── Bottom bar ── */
    #bottom-bar {
        dock: bottom;
        height: 1;
        background: #16161e;
        color: #565f89;
        padding: 0 1;
    }
    """

    BINDINGS = [
        Binding("ctrl+q", "quit_app", "Quit", show=False),
        Binding("ctrl+r", "run_council", "Run", show=False),
        Binding("escape", "focus_input", show=False),
    ]

    # ── State ──
    question: str = ""
    history: list = []
    is_thinking: bool = False
    _streaming_header_written: bool = False

    def compose(self) -> ComposeResult:
        yield Static(self._top_bar_text(), id="top-bar")
        with Vertical(id="chat-area"):
            yield RichLog(highlight=True, markup=True, wrap=True, id="chat-log")
        yield Static(self._bottom_bar_text(), id="bottom-bar")
        with Horizontal(id="input-area"):
            yield Static("[#7aa2f7 bold]❯[/#7aa2f7 bold] ", id="prompt-indicator")
            yield PromptInput(id="prompt-input")

    def on_mount(self) -> None:
        log = self.query_one("#chat-log", RichLog)
        log.write("")
        log.write("[bold #c0caf5]  Claude Council[/bold #c0caf5]")
        log.write("[#565f89]  Session Prep — refine your question before deliberation[/#565f89]")
        log.write("[#565f89]  Type your question below, or /help for commands[/#565f89]")
        log.write("")
        self.query_one("#prompt-input", PromptInput).focus()

    # ── Top & bottom bars ──

    def _top_bar_text(self) -> str:
        flags = []
        if FLAGS["review"]:    flags.append("review")
        if FLAGS["nexus"]:     flags.append("nexus")
        if FLAGS["quick"]:     flags.append("quick")
        if FLAGS["no_stream"]: flags.append("no-stream")
        mode = " + ".join(flags) if flags else "standard"
        q_hint = ""
        if self.question:
            preview = self.question.split("\n")[0][:50]
            ellipsis = "…" if len(self.question.split("\n")[0]) > 50 else ""
            q_hint = f"  ┃  {preview}{ellipsis}"
        return f" ⚖  Council Prep  ┃  {mode}{q_hint}"

    def _bottom_bar_text(self) -> str:
        return " enter send  \\+enter newline  ctrl+j newline  /help commands  ctrl+r run  ctrl+q quit"

    def _update_bars(self) -> None:
        self.query_one("#top-bar", Static).update(self._top_bar_text())

    # ── Input handling ──

    @on(PromptInput.Submitted)
    async def on_prompt_submitted(self, event: PromptInput.Submitted) -> None:
        text = event.value.strip()
        if not text:
            return
        await self._handle_input(text)

    async def _handle_input(self, text: str) -> None:
        """Process user input — slash commands or message to chairman."""
        log = self.query_one("#chat-log", RichLog)

        # ── Paste condensing ──
        display_text, full_text = self._maybe_condense(text)

        # ── Slash commands (handled locally, never sent to chairman) ──
        stripped = full_text.strip()

        if stripped == "/help":
            log.write("")
            log.write(HELP_TEXT)
            log.write("")
            return

        if stripped in ("/quit", "/exit"):
            self.exit(result=None)
            return

        if stripped == "/run":
            if not self.question:
                log.write("[#e0af68]  No question set yet. Enter your question first.[/#e0af68]")
                return
            self.exit(result="run")
            return

        if stripped == "/question":
            if not self.question:
                log.write("[#e0af68]  No question set yet.[/#e0af68]")
            else:
                lines = self.question.count("\n") + 1
                if lines > 6:
                    preview = self.question.split("\n")[0][:70]
                    log.write(f"[bold #c0caf5]  Current question:[/bold #c0caf5]")
                    log.write(f"  [#a9b1d6]{rich_escape(preview)}…[/#a9b1d6]")
                    log.write(f"  [#565f89]({lines} lines total)[/#565f89]")
                else:
                    log.write(f"[bold #c0caf5]  Current question:[/bold #c0caf5]")
                    log.write(f"  [#a9b1d6]{rich_escape(self.question)}[/#a9b1d6]")
            return

        if stripped == "/edit":
            self.question = ""
            self.history = []
            self._update_bars()
            log.write("[#9ece6a]  Question cleared. Enter a new one.[/#9ece6a]")
            return

        if stripped == "/review":
            FLAGS["review"] = not FLAGS["review"]
            state = "[#9ece6a]on[/#9ece6a]" if FLAGS["review"] else "[#565f89]off[/#565f89]"
            log.write(f"  review {state}")
            if FLAGS["review"] and FLAGS["quick"]:
                FLAGS["quick"] = False
                log.write("[#565f89]  (turned off /quick — incompatible with /review)[/#565f89]")
            self._update_bars()
            return

        if stripped == "/nexus":
            FLAGS["nexus"] = not FLAGS["nexus"]
            state = "[#9ece6a]on[/#9ece6a]" if FLAGS["nexus"] else "[#565f89]off[/#565f89]"
            log.write(f"  nexus {state}")
            self._update_bars()
            return

        if stripped == "/quick":
            FLAGS["quick"] = not FLAGS["quick"]
            state = "[#9ece6a]on[/#9ece6a]" if FLAGS["quick"] else "[#565f89]off[/#565f89]"
            log.write(f"  quick {state}")
            if FLAGS["quick"] and FLAGS["review"]:
                FLAGS["review"] = False
                log.write("[#565f89]  (turned off /review — incompatible with /quick)[/#565f89]")
            self._update_bars()
            return

        if stripped in ("/no-stream", "/nostream", "/no_stream"):
            FLAGS["no_stream"] = not FLAGS["no_stream"]
            state = "[#9ece6a]on[/#9ece6a]" if FLAGS["no_stream"] else "[#565f89]off[/#565f89]"
            log.write(f"  no-stream {state}")
            self._update_bars()
            return

        if stripped == "/flags":
            on = "[#9ece6a bold]on[/#9ece6a bold]"
            off = "[#565f89]off[/#565f89]"
            log.write("")
            log.write(
                f"  [bold #c0caf5]Session flags[/bold #c0caf5]\n"
                f"  review     {on if FLAGS['review'] else off}\n"
                f"  nexus      {on if FLAGS['nexus'] else off}\n"
                f"  quick      {on if FLAGS['quick'] else off}\n"
                f"  no-stream  {on if FLAGS['no_stream'] else off}"
            )
            return

        if stripped.startswith("/"):
            log.write(f"[#e0af68]  Unknown command: {rich_escape(stripped)}[/#e0af68]")
            log.write("[#565f89]  Type /help for commands[/#565f89]")
            return

        # ── Not a command — treat as message ──
        log.write("")
        log.write(f"[bold #7aa2f7]  You [/bold #7aa2f7][#a9b1d6]{rich_escape(display_text)}[/#a9b1d6]")

        if not self.question:
            # First message — this becomes the question
            self.question = full_text
            self.history = [{"role": "user", "text": full_text}]
            self._update_bars()
            self._ask_chairman_initial()
        else:
            # Follow-up message
            self.history.append({"role": "user", "text": full_text})
            if len(full_text) > 20:
                self.question += f"\n\nAdditional context:\n{full_text}"
                self._update_bars()
            self._ask_chairman_followup(full_text)

    # ── Paste condensing ──

    def _maybe_condense(self, text: str) -> tuple:
        """Returns (display_text, full_text). Condenses long pastes."""
        global _next_paste_id
        line_count = text.count("\n") + 1

        if line_count > PASTE_LINE_THRESHOLD or len(text) > PASTE_CHAR_THRESHOLD:
            paste_id = _next_paste_id
            _next_paste_id += 1
            _pasted_contents[paste_id] = text

            first_line = text.split("\n")[0][:60]
            if len(first_line) < len(text.split("\n")[0]):
                first_line += "…"

            display = f"[#565f89]\\[Pasted #{paste_id} · {line_count} lines] {rich_escape(first_line)}[/#565f89]"
            return display, text
        else:
            return text, text

    # ── Chairman calls (async workers) with live streaming ──

    @work(thread=False)
    async def _ask_chairman_initial(self) -> None:
        """Ask chairman to review the initial question."""
        log = self.query_one("#chat-log", RichLog)
        log.write("")
        log.write("[bold #bb9af7]  Chairman [/bold #bb9af7][#565f89]thinking…[/#565f89]")
        self.is_thinking = True
        self._streaming_header_written = False

        prompt = (
            f"The user wants to bring this question to the council for deliberation:\n\n"
            f"---\n{self.question}\n---\n\n"
            f"Help them refine this into a clear, specific question for the council. "
            f"If it's already clear, confirm it's ready and suggest they type /run."
        )

        try:
            response = await call_chairman_streaming(
                prompt,
                on_token=self._on_chairman_token,
            )
        except Exception as e:
            log.write(f"[#f7768e]  Error: {rich_escape(str(e))}[/#f7768e]")
            response = None

        self.is_thinking = False

        if response:
            # Clear the "thinking…" line and write the full clean response
            self._finalize_chairman_response(response)
            self.history.append({"role": "chairman", "text": response})
        else:
            try:
                response = await call_chairman_sync(prompt)
                if response:
                    self._finalize_chairman_response(response)
                    self.history.append({"role": "chairman", "text": response})
                else:
                    log.write("[#e0af68]  No response. Type /run to proceed anyway.[/#e0af68]")
            except Exception:
                log.write("[#e0af68]  No response. Type /run to proceed anyway.[/#e0af68]")

    @work(thread=False)
    async def _ask_chairman_followup(self, user_msg: str) -> None:
        """Ask chairman about follow-up input."""
        log = self.query_one("#chat-log", RichLog)
        log.write("")
        log.write("[bold #bb9af7]  Chairman [/bold #bb9af7][#565f89]thinking…[/#565f89]")
        self.is_thinking = True
        self._streaming_header_written = False

        conv_history = "\n".join(
            f"{'User' if h['role'] == 'user' else 'Chairman'}: {h['text']}"
            for h in self.history
        )

        prompt = (
            f"You are helping refine a council question.\n\n"
            f"Original question:\n{self.question}\n\n"
            f"Conversation so far:\n{conv_history}\n\n"
            f"Latest user message: {user_msg}\n\n"
            f"If the user provided additional context or clarification, "
            f"incorporate it and suggest an updated question. "
            f"If the question is ready, say so."
        )

        try:
            response = await call_chairman_streaming(
                prompt,
                on_token=self._on_chairman_token,
            )
        except Exception as e:
            log.write(f"[#f7768e]  Error: {rich_escape(str(e))}[/#f7768e]")
            response = None

        self.is_thinking = False

        if response:
            self._finalize_chairman_response(response)
            self.history.append({"role": "chairman", "text": response})
        elif not response:
            log.write("[#e0af68]  No response. Type /run when ready.[/#e0af68]")

    def _on_chairman_token(self, token: str) -> None:
        """Called for each streaming token — write directly to log."""
        log = self.query_one("#chat-log", RichLog)
        if not self._streaming_header_written:
            # Remove the "thinking…" line by clearing last line approach
            # Since RichLog doesn't support removing lines, we just write the header
            log.write("")
            log.write(f"[bold #bb9af7]  Chairman[/bold #bb9af7]")
            self._streaming_header_written = True
        # Write token directly — RichLog.write appends, giving a streaming feel
        # We use markup=False to avoid rich markup in the chairman's response
        log.write(f"  [#a9b1d6]{rich_escape(token)}[/#a9b1d6]")

    def _finalize_chairman_response(self, response: str) -> None:
        """Replace streamed chunks with the clean final response."""
        log = self.query_one("#chat-log", RichLog)
        log.clear()
        self._replay_history_to_log(response)

    def _replay_history_to_log(self, latest_chairman_response: str = None) -> None:
        """Re-render the full conversation history to the log."""
        log = self.query_one("#chat-log", RichLog)

        # Opening header
        log.write("")
        log.write("[bold #c0caf5]  Claude Council[/bold #c0caf5]")
        log.write("[#565f89]  Session Prep — refine your question before deliberation[/#565f89]")
        log.write("")

        for entry in self.history:
            if entry["role"] == "user":
                display, _ = self._maybe_condense(entry["text"])
                log.write(f"[bold #7aa2f7]  You [/bold #7aa2f7][#a9b1d6]{rich_escape(display)}[/#a9b1d6]")
                log.write("")
            else:
                log.write(f"[bold #bb9af7]  Chairman[/bold #bb9af7]")
                for para in entry["text"].split("\n"):
                    if para.strip():
                        log.write(f"  [#a9b1d6]{rich_escape(para)}[/#a9b1d6]")
                log.write("")

        if latest_chairman_response:
            log.write(f"[bold #bb9af7]  Chairman[/bold #bb9af7]")
            for para in latest_chairman_response.split("\n"):
                if para.strip():
                    log.write(f"  [#a9b1d6]{rich_escape(para)}[/#a9b1d6]")
            log.write("")

    # ── Actions ──

    def action_quit_app(self) -> None:
        self.exit(result=None)

    def action_run_council(self) -> None:
        if self.question:
            self.exit(result="run")
        else:
            log = self.query_one("#chat-log", RichLog)
            log.write("[#e0af68]  No question set yet.[/#e0af68]")

    def action_focus_input(self) -> None:
        self.query_one("#prompt-input", PromptInput).focus()


# ═══════════════════════════════════════════════════════════════════════
# Entry point — run the app and output results for council.sh
# ═══════════════════════════════════════════════════════════════════════

def main():
    parse_args()

    app = SessionPrepApp()
    result = app.run()

    if result != "run" or not app.question:
        # User quit without running
        sys.exit(0)

    # ── Build final question with context ──
    final_question = app.question

    user_additions = [
        h["text"] for h in app.history
        if h["role"] == "user" and h["text"] != app.question
    ]
    if user_additions:
        final_question += "\n\n## Additional Context from Prep Session\n"
        for addition in user_additions:
            if len(addition) > 10:
                final_question += f"\n{addition}"

    # ── Write outputs for council.sh ──
    question_file = os.environ.get("COUNCIL_QUESTION_FILE", "")
    if question_file:
        with open(question_file, "w") as f:
            f.write(final_question)
    else:
        print("__COUNCIL_QUESTION_START__")
        print(final_question)
        print("__COUNCIL_QUESTION_END__")

    flags_file = os.environ.get("COUNCIL_FLAGS_FILE", "")
    if flags_file:
        with open(flags_file, "w") as f:
            json.dump(FLAGS, f)


if __name__ == "__main__":
    main()
