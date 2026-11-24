# modules/claude-statusline.nix
# The Claude Code statusLine command as a store package: bin/claude-statusline, python3 pinned.
# Prints `$cost | ctx <tokens> (P%) | cm -<K> | hr total -<K> (<pct>%)`. Reads this session's
# context-mode savings (~/.context-mode/projects/*/context.db) and headroom's (~/.headroom). No network.
{ pkgs }:
pkgs.runCommand "claude-statusline" { } ''
  mkdir -p $out/bin
  { echo '#!${pkgs.python3}/bin/python3'; tail -n +2 ${./claude-statusline/statusline}; } > $out/bin/claude-statusline
  chmod +x $out/bin/claude-statusline
''
