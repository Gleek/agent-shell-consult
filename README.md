# agent-shell-switch

A `completing-read` switcher for active
[agent-shell](https://github.com/xenodium/agent-shell) buffers.

Candidates are grouped by project. Each row contains an aligned status column
and, for ready agents, the time since the last ACP activity.

When Consult is installed, moving through the candidates previews each agent
shell. Aborting restores the previous buffer. The command falls back to plain
`completing-read` when Consult is unavailable.

## Usage

```elisp
(use-package agent-shell-switch
  :ensure (:host github :repo "Gleek/agent-shell-switch")
  :after agent-shell
  :bind (("C-c q b" . agent-shell-switch)
         (:map agent-shell-mode-map
               ("C-z b" . agent-shell-switch))))
```

Without `use-package`:

```elisp
(require 'agent-shell-switch)
(global-set-key (kbd "C-c q b") #'agent-shell-switch)
```

Run `M-x agent-shell-switch`, select a buffer, and press Enter.

The status snapshot recognizes agents that are working, ready, starting, or
waiting for a permission response.
