# modules/home/agent-hooks-lib.nix
# Per-harness tables for the neutral hook manifest (see agent-plugins-lib.nix `validateHooks`): which
# native event and tool each neutral name maps to, which events can veto, the Codex renderer, and the
# hook x harness coverage matrix. Sources: the harness spike of 2026-11-19 (nixpkgs unstable versions);
# entries marked UNVERIFIED were not confirmed on the pinned binary. `null` means the harness has no such
# event or tool, which the matrix reports as n/a instead of dropping the hook silently.
{ lib, plugins }:
let
  # events.<neutral>: { event, matcher? } for the JSON harnesses (Claude, Codex), a native event name for
  # the JS harnesses (omp, pi, opencode). tools.<alias>: a matcher string, or null.
  # `canBlock` for claude and codex lists prompt.submit and stop as well: the spike covers PreToolUse only,
  # the other two are from the docs (UNVERIFIED on the pinned binaries).
  # Events a hook can veto on Claude and Codex.
  jsonCanBlock = [
    "tool.before"
    "prompt.submit"
    "stop"
  ];
  table = {
    claude = {
      inherit (plugins.claudeTables) events tools;
      # A raw `matcher` on a tool event is Claude vocabulary: only Claude renders it.
      rawToolMatcher = true;
      canBlock = jsonCanBlock;
    };
    # Codex: Claude's JSON shape. file.read, ask.user, message.send and wake.schedule have no hook
    # matcher name that was confirmed (UNVERIFIED), so they are n/a.
    codex = {
      canBlock = jsonCanBlock;
      # Base statuses reported with an `-unverified` suffix: no Codex hook was ever run (see rootVar).
      unverified = [
        "block"
        "warn"
      ];
      # UNVERIFIED: the spike found PLUGIN_ROOT in the Codex docs (with CLAUDE_PLUGIN_* aliases) but never ran
      # a Codex hook. A shell fallback for an unset variable is not safe in a quoted command, so none here.
      rootVar = "PLUGIN_ROOT";
      events = {
        "session.start".event = "SessionStart";
        "session.end".event = "SessionEnd";
        "prompt.submit".event = "UserPromptSubmit";
        "tool.before".event = "PreToolUse";
        "tool.after".event = "PostToolUse";
        "subagent.start".event = "SubagentStart";
        "stop".event = "Stop";
        "compact" = {
          event = "SessionStart";
          matcher = "compact";
        };
      };
      tools = {
        "shell" = "Bash";
        "file.read" = null;
        "file.edit" = "apply_patch";
        "agent.spawn" = "Agent";
        "ask.user" = null;
        "message.send" = null;
        "wake.schedule" = null;
        "file.search" = null;
      };
    };
    # oh-my-pi extension events and tool names (docs v19.0.0). `stop` has no event; peer messaging is a
    # `write` to agent://<id>, not a tool, so message.send is n/a.
    omp = {
      implemented = [ "tool.before" ];
      canBlock = [
        "tool.before"
        "subagent.start"
      ];
      events = {
        "session.start" = "session_start";
        "session.end" = "session_shutdown";
        "prompt.submit" = "input";
        "tool.before" = "tool_call";
        "tool.after" = "tool_result";
        "subagent.start" = "before_subagent_spawn";
        "stop" = null;
        "compact" = "session_compact";
      };
      tools = {
        "shell" = "bash";
        "file.read" = "read";
        "file.edit" = "edit|write|ast_edit";
        "agent.spawn" = "task";
        "ask.user" = "ask";
        "message.send" = null;
        "wake.schedule" = null;
        "file.search" = "grep|glob|find";
      };
    };
    # Pi (docs v1.5.2; nixpkgs 26.05 ships 0.75.4, UNVERIFIED there). No native subagents, ask or stop event.
    pi = {
      implemented = [ "tool.before" ];
      canBlock = [ "tool.before" ];
      # tool_call has no additionalContext channel: a warn hook there is silent.
      noContext = [ "tool.before" ];
      events = {
        "session.start" = "session_start";
        "session.end" = "session_shutdown";
        "prompt.submit" = "input";
        "tool.before" = "tool_call";
        "tool.after" = "tool_result";
        "subagent.start" = null;
        "stop" = null;
        "compact" = "session_compact";
      };
      tools = {
        "shell" = "bash|powershell";
        "file.read" = "read";
        "file.edit" = "edit|write";
        "agent.spawn" = null;
        "ask.user" = null;
        "message.send" = null;
        "wake.schedule" = null;
        "file.search" = "grep|find|ls";
      };
    };
    # OpenCode 2.x (docs; the veto shape and the input rewrite are UNVERIFIED on 2.3.0). 2.x has no
    # session start, session end, stop or subagent hook.
    opencode = {
      implemented = [ ];
      canBlock = [ "tool.before" ];
      events = {
        "session.start" = null;
        "session.end" = null;
        "prompt.submit" = "prompt";
        "tool.before" = "execute.before";
        "tool.after" = "execute.after";
        "subagent.start" = null;
        "stop" = null;
        "compact" = "compaction";
      };
      tools = {
        "shell" = "shell";
        "file.read" = "read";
        "file.edit" = "edit|write";
        "agent.spawn" = "subagent";
        "ask.user" = "question";
        "message.send" = null;
        "wake.schedule" = null;
        "file.search" = null;
      };
    };
  };

  # One hook on one harness: the first status that applies.
  #   n/a            the harness has no such event or tool (every alias missing).
  #   claude-only    a raw `matcher` on a tool event: Claude vocabulary, no other harness renders it.
  #   no-shim        the event and tool exist but the harness shim does not read that event yet (omp and Pi
  #                  read tool.before only; opencode has no shim).
  #   partial        several tool aliases and the harness has only some (those are still rendered): check
  #                  the aliases. It hides the block/warn distinction.
  #   block          enforce=block on an event the harness can veto.
  #   unblockable    enforce=block on an event it cannot veto.
  #   silent         a warn hook on an event with no context channel (`noContext`, Pi tool.before). It
  #                  means no context channel, not no effect: a rewrite still applies, and an asking hook
  #                  (ask/defer) still blocks, whatever `enforce` is.
  #   warn           enforce=warn.
  # block and warn carry an `-unverified` suffix on a harness whose table lists them in `unverified`
  # (Codex: PLUGIN_ROOT was never run). The shims pass tool_input untranslated: only shell is known to carry
  # the same field (`command`) as Claude, so a hook keyed on file_path or pattern may not match on omp or Pi.
  status =
    t: h:
    let
      ev = t.events.${h.event};
      mapped = plugins.mappedTools t.tools h;
      partial = mapped != null && builtins.length mapped < builtins.length h.tools;
      rawOnTool = h ? matcher && builtins.elem h.event plugins.toolEvents;
      base =
        if h.enforce == "block" then
          if builtins.elem h.event t.canBlock then "block" else "unblockable"
        else if builtins.elem h.event (t.noContext or [ ]) then
          "silent"
        else
          "warn";
    in
    if ev == null || (mapped != null && mapped == [ ]) then
      "n/a"
    else if rawOnTool && !(t.rawToolMatcher or false) then
      "claude-only"
    else if t ? implemented && !(builtins.elem h.event t.implemented) then
      "no-shim"
    else if partial then
      "partial"
    else if builtins.elem base (t.unverified or [ ]) then
      "${base}-unverified"
    else
      base;
  statusReason =
    harness: h: st:
    if st == "claude-only" then
      "claude-only: a raw matcher on a tool event"
    else if st == "no-shim" then
      "no-shim: the ${harness} shim does not read ${h.event} yet"
    else
      "n/a: ${harness} has no ${h.event} event or none of the listed tools";
  # In the generated module a hook id sits in a `//` comment: no line break may survive.
  oneLine =
    let
      breaks = [
        "\n"
        "\r"
        (builtins.fromJSON ''"\u2028"'')
        (builtins.fromJSON ''"\u2029"'')
      ];
    in
    builtins.replaceStrings breaks (map (_: " ") breaks);
in
rec {
  harnesses = lib.sort builtins.lessThan (builtins.attrNames table);

  inherit table;

  # What a JS shim (omp, pi) reads: `hooks`, the tool.before hooks with the harness's own tool patterns in
  # manifest order, and `dropped`, [{ id, reason }] for every hook left out (shown in the matrix too).
  shimPlan =
    harness: manifest:
    let
      t = table.${harness};
      errors = plugins.validateHooks manifest;
      st = h: status t h;
      used =
        h:
        !(builtins.elem (st h) [
          "n/a"
          "claude-only"
          "no-shim"
        ]);
    in
    if !(t ? implemented) then
      throw "${harness}: not a JS-shim harness (its hooks are rendered as JSON)"
    else if errors != [ ] then
      throw "invalid hook manifest: ${lib.concatStringsSep "; " errors}"
    else
      {
        hooks = lib.concatMap (
          h:
          let
            mapped = plugins.mappedTools t.tools h;
          in
          lib.optional (used h) (
            {
              inherit (h) id script enforce;
              tools = if mapped == null then null else lib.concatStringsSep "|" mapped;
            }
            // lib.optionalAttrs ((h.timeout or null) != null) { inherit (h) timeout; }
          )
        ) manifest.hooks;
        dropped = lib.concatMap (
          h:
          lib.optional (!(used h)) {
            inherit (h) id;
            reason = statusReason harness h (st h);
          }
        ) manifest.hooks;
      };

  shimSpec = harness: manifest: (shimPlan harness manifest).hooks;

  # The JS module a harness loads for one plugin: a comment per dropped hook, then the adapter from the
  # runtime dir, baked with the plugin root and the spec.
  renderShim =
    {
      harness,
      manifest,
      root,
      runtime,
    }:
    let
      t = table.${harness};
      noShim = !(t ? implemented) || t.implemented == [ ];
      fn = "${harness}Extension";
      plan = shimPlan harness manifest;
      spec = builtins.toJSON {
        inherit root;
        inherit (plan) hooks;
      };
      notes = lib.concatMapStrings (
        d: "// hook ${oneLine d.id} is not in this shim: ${d.reason}\n"
      ) plan.dropped;
    in
    if noShim then
      throw (noShimError harness)
    else
      notes
      + ''
        import { ${fn} } from "${runtime}/adapters.mjs";
        export default ${fn}(${spec});
      '';

  noShimError = harness: "no shim for ${harness}";

  # Tests only: renderShim's refusal as data (`{ error }`), since a throw's message is not readable in Nix.
  renderShimChecked =
    args:
    let
      t = table.${args.harness};
    in
    if !(t ? implemented) || t.implemented == [ ] then
      { error = noShimError args.harness; }
    else
      { text = renderShim args; };

  # Claude and Codex read the same JSON; only the tool names and the plugin root variable differ.
  renderCodexHooks =
    manifest:
    plugins.renderGrouped {
      inherit manifest;
      inherit (table.codex) events tools rootVar;
      rawToolMatcher = false;
    };

  # harness -> hook id -> status, for a validated manifest. Throws on an invalid manifest.
  coverage =
    manifest:
    let
      errors = plugins.validateHooks manifest;
    in
    if errors != [ ] then
      throw "invalid hook manifest: ${lib.concatStringsSep "; " errors}"
    else
      lib.mapAttrs (
        _: t: lib.listToAttrs (map (h: lib.nameValuePair h.id (status t h)) manifest.hooks)
      ) table;
}
