# Agent Shell Consult

Agent Shell now includes `agent-shell-switch-buffer`. This package keeps the
native switcher as its fallback and adds a richer interface when Consult is
installed.

The Consult view preserves agent-shell's recent-buffer order and moves the
current buffer to the bottom. When every buffer uses the same agent, it removes
the repeated agent prefix from the candidate names. Preview, selection, and
Embark actions still resolve each candidate to its full buffer name. It also
adds:

- project, status, idle time, and session-title columns;
- matching by project, buffer name, or session title;
- narrowing by current project or shell state;
- live preview while moving between candidates;
- agent-shell's icons and buffer-name faces;
- a dedicated Embark action map.

## Installation

```elisp
(use-package agent-shell-consult
  :ensure (:host github :repo "Gleek/agent-shell-consult")
  :after agent-shell
  :bind (("C-c q b" . agent-shell-consult)
         (:map agent-shell-mode-map
               ("C-z b" . agent-shell-consult))))
```

Without Consult, `agent-shell-consult` delegates selection to agent-shell's
native reader. Existing `agent-shell-switch` configurations continue to work
through a compatibility shim.

## Embark actions

| Key | Action |
|---|---|
| `RET` | Switch to the agent shell |
| `k` | Kill the agent-shell buffer |
| `K` | Stop the agent process |
| `r` | Restart the agent shell |
| `R` | Reload the current session |
| `m` | Set the session mode |
| `l` | Set the model |
| `i` | Interrupt the current request |
| `t` | Open the session transcript |
| `L` | Toggle ACP logging |
| `T` | View ACP traffic |
