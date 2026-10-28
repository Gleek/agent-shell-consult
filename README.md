# Agent Shell Consult

A Consult interface for managing agent-shell buffers.
Acts like an enhanced version `agent-shell-switch-buffer`, with session details,
live previews, and Embark actions.


<img width="3600" height="1260" alt="agent-shell-consult-annotated-v3" src="https://github.com/user-attachments/assets/44d66858-cc13-4e91-875b-a93cabc372a4" />



- See each session's project, state, idle time, and title.
- Search by buffer name, project, or session title.
- Filter by current project or state, including drafts.
- Preview sessions as you move through the list.
- Browse Active, Inactive, and Saved sessions in separate groups.
- Resume saved sessions across configured agents and projects.
- Use Embark to interrupt, restart, change models, and more.

Ready sessions with unsent text show **Draft** in red and stay Active.
Use the `d` filter to find them.

With [agent-shell-attention](https://github.com/ultronozm/agent-shell-attention.el),
a **●** beside the state marks unread output.
Selecting a session clears the indicator; previewing leaves it unread.
Pending permissions remain.

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

## Saved sessions

Enable saved sessions for your agents:

```elisp
(setq agent-shell-consult-session-agents
      '(agent-shell-anthropic-make-claude-code-config
        agent-shell-openai-make-codex-config))
```

Requires Consult, Agent Shell 0.83.4+, and acp.el 0.18.1+.
The default is nil (existing buffers only). Config alists are also accepted.

## Embark actions

Existing buffers offer:

| Key   | Action                        |
|-------|-------------------------------|
| `RET` | Switch to the agent shell     |
| `f`   | Fork into a separate session  |
| `k`   | Kill the agent-shell buffer   |
| `K`   | Stop the agent process        |
| `r`   | Rename the buffer             |
| `R`   | Reload the current session    |
| `n`   | New shell in the same project |
| `m`   | Set the session mode          |
| `l`   | Set the model                 |
| `i`   | Interrupt the current request |
| `t`   | Open the session transcript   |
| `L`   | Toggle ACP logging            |
| `T`   | View ACP traffic              |

Saved sessions offer:

| Key   | Action                               |
|-------|--------------------------------------|
| `RET` | Resume the session                   |
| `f`   | Fork into a separate session         |
| `w`   | Copy the session ID                  |
| `d`   | Open the working directory in Dired   |
| `c`   | Copy a native CLI resume command     |
| `t`   | View an existing Agent Shell transcript |
