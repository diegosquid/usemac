# Native background scroll of a plain web page in a UseMac Chrome window. Either background path may move it: the
# wheel event posted to Chrome, or (Chrome ignores that one today) the next offscreen element scrolled into view.
# What must hold: the page moves, and another UseMac window gets neither scrolled nor any wheel event.

SMOKE_DESC="Chrome: background scroll of web content (native act in a UseMac window), no other window touched"
SMOKE_NEEDS="chrome"
# Needs browser open --new-window, so native observe sees the page without touching the user's windows.
SMOKE_MIN_EXT="0.6.0-beta.1"

smoke_case() {
  . "$SMOKE_ROOT/include/scroll.sh"
  run_scroll_case 0
}
