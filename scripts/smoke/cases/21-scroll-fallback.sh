# Native background scroll of a page that swallows wheel events: UseMac scrolls the next offscreen element into
# view instead (AXScrollToVisible, mechanism ax-scroll-to-next).

SMOKE_DESC="Chrome: background scroll fallback, scrolling the next offscreen element into view"
SMOKE_NEEDS="chrome"
SMOKE_MIN_EXT="0.6.0-beta.1"

smoke_case() {
  . "$SMOKE_ROOT/include/scroll.sh"
  run_scroll_case 1
}
