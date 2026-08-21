# Agent Shell Consult

Agent Shell now includes `agent-shell-switch-buffer`. This package keeps the
native switcher as its fallback and adds a richer interface when Consult is
installed.

The Consult view preserves agent-shell's recent-buffer order and moves the
current buffer to the bottom. It adds:

- project, status, idle time, and session-title columns;
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
| `k` | Stop the agent process |
| `c` | Create a new agent shell |
| `r` | Restart the agent shell |
| `d` | Delete all stopped agent-shell buffers |
| `m` | Set the session mode |
| `M` | Set the model |
| `C-c C-c` | Interrupt the current request |
| `t` | View ACP traffic |
| `l` | Toggle ACP logging |
