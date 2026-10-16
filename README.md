# Agent Shell Consult



<img width="1757" height="740" alt="agent-shell-consult" src="https://github.com/user-attachments/assets/7cf90964-68cd-4c0a-acd0-ee87a25a2c11" />

A Consult interface for managing agent-shell buffers.
Acts like an enhanced version `agent-shell-switch-buffer`, with session details,
live previews, and Embark actions.

- See each session's project, state, idle time, and title.
- Search by buffer name, project, or session title.
- Filter by current project or state, including drafts.
- Preview sessions as you move through the list.
- Find active sessions together, with older sessions grouped below.
- Use Embark to interrupt, restart, change models, and more.

Ready sessions with unsent text show **Draft** in red and stay Active.
Use the `d` filter to find them.

With [agent-shell-attention](https://github.com/ultronozm/agent-shell-attention.el),
a **●** beside the state marks unread output.
Previewing or opening that session clears the indicator; pending permissions
remain.

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
native reader.

## Embark actions

| Key   | Action                        |
|-------|-------------------------------|
| `RET` | Switch to the agent shell     |
| `k`   | Kill the agent-shell buffer   |
| `K`   | Stop the agent process        |
| `r`   | Restart the agent shell       |
| `R`   | Reload the current session    |
| `m`   | Set the session mode          |
| `l`   | Set the model                 |
| `i`   | Interrupt the current request |
| `t`   | Open the session transcript   |
| `L`   | Toggle ACP logging            |
| `T`   | View ACP traffic              |
