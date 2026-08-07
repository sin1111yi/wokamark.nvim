-- wokamark.config — configuration defaults (zero hardcoding: all tunables
-- live here, overridable through setup())

return {
  auto_mark = true, -- debounced auto-marking on file events
  debounce = 30,    -- seconds between auto-marks for the same cwd
}
