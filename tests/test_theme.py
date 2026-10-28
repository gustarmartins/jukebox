import os
from pathlib import Path
import re
import shlex
import subprocess

import pytest


APP = Path(__file__).parents[1] / "jukebox"
SGR = re.compile(r"\x1b\[[0-9;]*m")


def render(code, color="1"):
    setup = f"source {shlex.quote(str(APP / 'src/theme.zsh'))}; source {shlex.quote(str(APP / 'src/ui.zsh'))}; _jukebox_theme_init; "
    return subprocess.run(["zsh", "-dfc", setup + code], capture_output=True, text=True, timeout=5,
                          env={**os.environ, "JUKEBOX_COLOR": color})


@pytest.mark.parametrize("width", [24, 40, 80, 120, 190])
def test_keycaps_measure_visible_width_and_reset_styles(width):
    result = render(f'_jukebox_control_row {width} "SPACE|Pause|0" "-/+|Volume|0" "M|Muted|1" "T|Repeat: track|1" "?|Help|0"')
    assert result.returncode == 0, result.stderr
    assert len(SGR.sub("", result.stdout)) == width
    assert result.stdout.endswith("\x1b[0m")
    assert "[SPACE]" in result.stdout
    if width >= 80:
        assert "\x1b[1;38;2;19;34;43;48;2;142;211;216m[M]" in result.stdout
        assert "\x1b[1;38;2;163;225;229;48;2;35;49;61m[SPACE]" in result.stdout


@pytest.mark.parametrize("position", [0, 50, 100, 200])
def test_progress_zero_full_and_overrun_stay_within_terminal(position):
    result = render(f'_render_time_pos={position}; _render_duration=100; _jukebox_progress_line 80')
    assert result.returncode == 0, result.stderr
    plain = SGR.sub("", result.stdout)
    assert len(plain) == 80
    if position == 0:
        assert "━" not in plain
    if position >= 100:
        assert "─" not in plain


def test_monochrome_override_retains_state_and_key_labels():
    result = render('_jukebox_control_row 100 "SPACE|Resume|1" "M|Muted|1" "T|Repeat: queue|1"', color="0")
    assert result.returncode == 0, result.stderr
    assert "\x1b[" not in result.stdout
    assert "[SPACE] Resume" in result.stdout
    assert "[M] Muted" in result.stdout
    assert "[T] Repeat: queue" in result.stdout
