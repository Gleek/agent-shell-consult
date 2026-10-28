;;; setup.el --- Install test dependencies -*- lexical-binding: t; -*-

;;; Commentary:
;; Use a separate package directory so tests do not depend on the user's setup.

;;; Code:

(require 'package)
(setq package-user-dir (expand-file-name "agent-shell-consult-elpa"
                                         temporary-file-directory)
      package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa" . "https://melpa.org/packages/")))
(package-initialize)
(package-refresh-contents)
(dolist (package '(agent-shell acp consult embark))
  (package-install package))

;;; setup.el ends here
