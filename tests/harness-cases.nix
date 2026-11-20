# Cases for the per-harness hook tables, the Codex renderer and the coverage matrix
# (modules/home/agent-hooks-lib.nix), shared by tests/harness-suite.sh standalone and the flake check.
{ lib, fix }:
let
  shared = import ./lib.nix { inherit lib fix; };
  inherit (shared) plugins byName h;
  l = import ../modules/home/agent-hooks-lib.nix { inherit lib plugins; };
  multi = byName.multi.hooks;
  rawMatcherHooks = {
    hooks = [
      (h "m" "tool.before" { matcher = "Grep|Glob"; })
    ];
  };
  searchHooks = {
    hooks = [
      (h "s" "tool.before" { tools = [ "file.search" ]; })
    ];
  };
  mixedHooks = {
    hooks = [
      (h "x" "tool.before" {
        tools = [
          "shell"
          "file.read"
        ];
      })
    ];
  };
in
{
  codexGated = l.renderCodexHooks byName.gated.hooks;
  codexMulti = l.renderCodexHooks multi;
  coverage = l.coverage multi;
  coverageGated = l.coverage byName.gated.hooks;
  unblockable = l.coverage {
    hooks = [
      (h "x" "session.start" { enforce = "block"; })
      (h "y" "tool.before" {
        tools = [ "shell" ];
        enforce = "block";
      })
    ];
  };
  # Several aliases, only some on the harness: codex has no file.read tool, pi has both.
  partial = l.coverage {
    hooks = [
      (h "g" "tool.before" {
        tools = [
          "shell"
          "file.read"
        ];
        enforce = "block";
      })
    ];
  };
  # A raw matcher on a tool event is Claude vocabulary; file.search is its neutral spelling.
  rawMatcherCoverage = l.coverage rawMatcherHooks;
  rawMatcherCodex = l.renderCodexHooks rawMatcherHooks;
  rawMatcherOmp = l.shimSpec "omp" rawMatcherHooks;
  rawMatcherPi = l.shimSpec "pi" rawMatcherHooks;
  searchCoverage = l.coverage searchHooks;
  searchOmp = l.shimSpec "omp" searchHooks;
  searchPi = l.shimSpec "pi" searchHooks;
  searchCodex = l.renderCodexHooks searchHooks;
  harnesses = l.harnesses;
  shimOmpMulti = l.shimSpec "omp" multi;
  shimPiMulti = l.shimSpec "pi" multi;
  shimOmpGated = l.shimSpec "omp" byName.gated.hooks;
  shimText = l.renderShim {
    harness = "omp";
    manifest = byName.gated.hooks;
    root = "/store/plugin";
    runtime = "/store/runtime";
  };
  shimOmpMixed = l.shimSpec "omp" mixedHooks;
  shimPiMixed = l.shimSpec "pi" mixedHooks;
  # S5: partial outranks silent (pi warn) and unblockable (tool.after block on codex).
  partialSilent = l.coverage {
    hooks = [
      (h "w" "tool.before" {
        tools = [
          "shell"
          "ask.user"
        ];
      })
      (h "u" "tool.after" {
        tools = [
          "shell"
          "file.read"
        ];
        enforce = "block";
      })
    ];
  };
  shimOpencodeError =
    (l.renderShimChecked {
      harness = "opencode";
      manifest = multi;
      root = "/r";
      runtime = "/rt";
    }).error;
  planRawOmp = l.shimPlan "omp" rawMatcherHooks;
  planGatedOmp = l.shimPlan "omp" byName.gated.hooks;
  shimInjection = l.renderShim {
    harness = "omp";
    manifest.hooks = [
      (h "evil" "session.start" { id = "evil\nimport x from \"y\""; })
    ];
    root = "/r";
    runtime = "/rt";
  };
  shimPiGated = l.shimSpec "pi" byName.gated.hooks;
  shimOpencodeFails =
    !(builtins.tryEval (
      builtins.deepSeq (l.renderShim {
        harness = "opencode";
        manifest = multi;
        root = "/r";
        runtime = "/rt";
      }) true
    )).success;
  shimCodexFails = !(builtins.tryEval (builtins.deepSeq (l.shimSpec "codex" multi) true)).success;
}
