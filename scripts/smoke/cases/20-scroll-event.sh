# Native background scroll of a web page in a UseMac Chrome window: the wheel event posted to Chrome moves the page.

SMOKE_DESC="Chrome: background scroll of web content with the wheel event (native act in a UseMac window)"
SMOKE_NEEDS="chrome"
# Needs browser open --new-window, so native observe sees the page without touching the user's windows.
SMOKE_MIN_EXT="0.6.0-beta.1"

smoke_case() {
  . "$SMOKE_ROOT/include/scroll.sh"
  run_scroll_case 0
}
