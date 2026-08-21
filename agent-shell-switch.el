;;; agent-shell-switch.el --- Compatibility shim -*- lexical-binding: t; -*-

(require 'agent-shell-consult)

(define-obsolete-function-alias 'agent-shell-switch #'agent-shell-consult "0.2.0")

(provide 'agent-shell-switch)

;;; agent-shell-switch.el ends here
