# Agent Shell Consult

A Consult interface for managing agent-shell buffers.
Acts like an enhanced version `agent-shell-switch-buffer`, with session details,
live previews, and Embark actions.

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

Choose which agents to query using their existing Agent Shell config makers:

```elisp
(setq agent-shell-consult-session-agents
      '(agent-shell-anthropic-make-claude-code-config
        agent-shell-openai-make-codex-config))
```

The default is nil, which keeps the picker limited to existing buffers.
Config alists from `agent-shell-make-agent-config` are also accepted.
Requires Agent Shell 0.83.4 or newer and acp.el 0.18.1 or newer, which
supports listing sessions across working directories.

Session lists stay cached for the lifetime of Emacs and appear immediately
when opening the picker. Lists older than 60 seconds refresh asynchronously,
replacing that agent's cached rows as results arrive. Failed refreshes keep
the previous results available. Set `agent-shell-consult-session-cache-ttl`
to change the refresh interval, or zero to refresh on every opening. Use
`M-x agent-shell-consult-refresh-sessions` or a prefix argument (`C-u`) with
`agent-shell-consult` to fetch fresh lists.

Existing buffers appear first, followed by **Saved sessions**, sorted by last
update across all queried agents and directories. Saved rows show the session
title, project, and age with the same time format and styling as buffer rows.
Sessions without titles show "Untitled session". Sessions already open are
filtered by agent and session ID each time, including when using cached lists.
Search by agent, directory, title, or session ID; use the `h`
narrowing key for saved sessions or `p` for the current project.

Press `RET` to resume a saved session in a new buffer using its original agent
config and directory. Previewing a saved session does not load it. Other Embark
actions apply to existing buffers. Saved sessions have their own Embark map;
process and buffer actions are only offered for buffers.

An unavailable agent, unsupported capability, or listing error leaves other
agents' results usable and reports the reason in `*Messages*`. Each query has a
30-second timeout, configurable with `agent-shell-consult-session-timeout`.
Closing the picker stops pending queries and releases their clients. Pagination
uses `agent-shell-session-list-page-limit`; leave it nil to fetch all pages.
Saved session browsing requires Consult; the native reader still lists buffers.

## Embark actions

Saved sessions offer:

| Key   | Action                               |
|-------|--------------------------------------|
| `RET` | Resume the session                   |
| `f`   | Fork into a separate session         |
| `w`   | Copy the session ID                  |
| `d`   | Open the working directory in Dired   |
| `c`   | Copy a native CLI resume command     |
| `t`   | View an existing Agent Shell transcript |

Forking copies the conversation into a new session while preserving the
original. Saved sessions can be forked when their agent advertises support;
otherwise the action reports that forking is unavailable. Refresh session
lists to recheck capabilities after updating an adapter.

Resume commands include changing to the original directory. Claude and Codex
are supported by default; customize `agent-shell-consult-resume-commands` for
other agents. Commands are copied, never executed.

Transcript viewing looks in the session's Agent Shell transcript directory,
using `agent-shell-dot-subdir-function`, and matches its session ID. It opens
an existing Markdown transcript read-only without starting an agent. Sessions
created outside Agent Shell may not have one.

Existing buffers offer:

| Key   | Action                        |
|-------|-------------------------------|
| `RET` | Switch to the agent shell     |
| `f`   | Fork into a separate session  |
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
