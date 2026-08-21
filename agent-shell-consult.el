;;; agent-shell-consult.el --- Consult UI for agent-shell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1") (agent-shell "0.73.2"))
;; Keywords: convenience, processes, tools
;; URL: https://github.com/Gleek/agent-shell-consult

;;; Commentary:
;;
;; Add a metadata-rich Consult interface and Embark actions to agent-shell's
;; native buffer switcher.  Without Consult, use agent-shell's native reader.

;;; Code:

(require 'agent-shell)
(require 'subr-x)

(declare-function consult--buffer-state "consult")
(declare-function consult--read "consult")
(declare-function agent-shell--buffer-name-prefix "agent-shell")
(declare-function agent-shell--config-icon "agent-shell")
(declare-function agent-shell--read-shell-buffer "agent-shell")
(defvar embark-keymap-alist)

(defun agent-shell-consult--buffer (candidate)
  "Return the live agent-shell buffer stored on CANDIDATE."
  (let ((buffer (get-text-property 0 'agent-shell-consult-buffer candidate)))
    (unless (buffer-live-p buffer)
      (user-error "Agent-shell buffer no longer exists"))
    buffer))

(defun agent-shell-consult--live-p (buffer)
  "Return non-nil when BUFFER's shell and ACP processes are alive."
  (with-current-buffer buffer
    (let ((client (map-elt agent-shell--state :client)))
      (and (process-live-p (get-buffer-process buffer))
           (or (not client)
               (process-live-p (map-elt client :process)))))))

(defun agent-shell-consult--duration (since now)
  "Format the elapsed time between SINCE and NOW."
  (let* ((seconds (max 0 (floor (float-time (time-subtract now since)))))
         (days (/ seconds 86400))
         (hours (/ (% seconds 86400) 3600))
         (minutes (/ (% seconds 3600) 60)))
    (cond ((> days 0) (format "%dd %dh" days hours))
          ((> hours 0) (format "%dh %dm" hours minutes))
          ((> minutes 0) (format "%dm" minutes))
          (t "<1m"))))

(defun agent-shell-consult--project (buffer)
  "Return BUFFER's project name."
  (with-current-buffer buffer
    (if (fboundp 'agent-shell--project-name)
        (agent-shell--project-name)
      (file-name-nondirectory
       (directory-file-name (expand-file-name default-directory))))))

(defun agent-shell-consult--status (buffer now)
  "Return BUFFER's faced status and idle age at NOW."
  (with-current-buffer buffer
    (let ((status (if (agent-shell-consult--live-p buffer)
                      (agent-shell-status :shell-buffer buffer)
                    'killed)))
      (list
       (pcase status
         ('blocked (propertize "Waiting" 'face 'agent-shell-error))
         ('busy (propertize "Working" 'face 'agent-shell-warning))
         ('killed (propertize "Killed" 'face 'agent-shell-error))
         ('ready
          (cond ((not (map-elt agent-shell--state :initialized))
                 (propertize "Starting..." 'face 'shadow))
                ((not (map-nested-elt agent-shell--state '(:session :id)))
                 (propertize "No Session" 'face 'shadow))
                (t (propertize "Ready" 'face 'agent-shell-success))))
         (_ (propertize "Unknown" 'face 'shadow)))
       (when-let* (((eq status 'ready))
                   (last-activity (map-elt agent-shell--state
                                           :last-activity-time)))
         (propertize (agent-shell-consult--duration last-activity now)
                     'face 'shadow))))))

(defun agent-shell-consult--buffers ()
  "Return agent-shell buffers with the current buffer last."
  (let ((buffers (agent-shell-buffers)))
    (if (memq (current-buffer) buffers)
        (append (delq (current-buffer) (copy-sequence buffers))
                (list (current-buffer)))
      buffers)))

(defun agent-shell-consult--entries (buffers)
  "Build completion entries for BUFFERS."
  (let* ((now (current-time))
         (identifiers
          (mapcar (lambda (buffer)
                    (with-current-buffer buffer
                      (map-nested-elt agent-shell--state
                                      '(:agent-config :identifier))))
                  buffers))
         (short-names (seq-every-p (lambda (id) (eq id (car identifiers)))
                                    identifiers)))
    (mapcar
     (lambda (buffer)
       (with-current-buffer buffer
         (pcase-let* ((`(,status ,age)
                       (agent-shell-consult--status buffer now))
                      (config (map-elt agent-shell--state :agent-config))
                      (prefix (agent-shell--buffer-name-prefix
                               (map-elt config :buffer-name)))
                      (name (if (and short-names prefix)
                                (string-remove-prefix prefix (buffer-name))
                              (buffer-name)))
                      (title (string-trim
                              (car (split-string
                                    (or (map-nested-elt agent-shell--state
                                                        '(:session :title)) "")
                                    "\n")))))
           (cons (propertize name
                             'face 'agent-shell-buffer-name
                             'agent-shell-consult-buffer buffer)
                 (list :buffer buffer
                       :icon (when agent-shell-show-config-icons
                               (agent-shell--config-icon :config config))
                       :project (agent-shell-consult--project buffer)
                       :status status
                       :age age
                       :title (truncate-string-to-width title 50 nil nil "..."))))))
     buffers)))

(defun agent-shell-consult--entry (candidate entries)
  "Return CANDIDATE's data from ENTRIES."
  (cdr (assoc-string candidate entries)))

(defun agent-shell-consult--affix (candidate entries widths)
  "Add metadata to CANDIDATE using ENTRIES and column WIDTHS."
  (let* ((entry (agent-shell-consult--entry candidate entries))
         (padding (+ 2 (- (nth 0 widths) (string-width candidate))))
         (project (plist-get entry :project))
         (status (plist-get entry :status))
         (age (or (plist-get entry :age) ""))
         (title (plist-get entry :title)))
    (list candidate
          (if-let* ((icon (plist-get entry :icon))) (concat icon " ") "")
          (concat (make-string padding ?\s)
                  (string-pad (propertize project 'face 'shadow) (nth 1 widths))
                  "  " (string-pad status (nth 2 widths))
                  "  " (string-pad age (nth 3 widths))
                  (unless (string-empty-p title)
                    (concat "  " (propertize title 'face
                                              'agent-shell-session-title)))))))

(defun agent-shell-consult--read (buffers)
  "Read one of BUFFERS with Consult and return it."
  (let* ((entries (agent-shell-consult--entries buffers))
         (candidates (mapcar #'car entries))
         (widths
          (mapcar (lambda (getter)
                    (apply #'max
                           (mapcar (lambda (entry)
                                     (string-width (or (funcall getter entry) "")))
                                   entries)))
                  (list #'car
                        (lambda (e) (plist-get (cdr e) :project))
                        (lambda (e) (plist-get (cdr e) :status))
                        (lambda (e) (plist-get (cdr e) :age)))))
         (annotate (lambda (candidate)
                     (agent-shell-consult--affix candidate entries widths)))
         (selection
          (consult--read candidates
                         :prompt "Switch to agent shell: "
                         :require-match t
                         :category 'agent-shell-consult-buffer
                         :sort nil
                         :annotate annotate
                         :state (consult--buffer-state)
                         :preview-key 'any)))
    (plist-get (agent-shell-consult--entry selection entries) :buffer)))

(defun agent-shell-consult--call (candidate function)
  "Call FUNCTION interactively in CANDIDATE's agent-shell buffer."
  (with-current-buffer (agent-shell-consult--buffer candidate)
    (call-interactively function)))

(defun agent-shell-consult-action-switch (candidate)
  "Switch to CANDIDATE."
  (interactive "sAgent shell: ")
  (switch-to-buffer (agent-shell-consult--buffer candidate)))

(defun agent-shell-consult-action-kill (candidate)
  "Stop CANDIDATE's agent process."
  (interactive "sAgent shell: ")
  (when (yes-or-no-p (format "Kill agent-shell process in %s? " candidate))
    (agent-shell-consult--call candidate #'comint-send-eof)))

(defun agent-shell-consult-action-new (_candidate)
  "Create a new agent shell."
  (interactive "sAgent shell: ")
  (agent-shell t))

(defun agent-shell-consult-action-delete-killed (_candidate)
  "Delete all stopped agent-shell buffers."
  (interactive "sAgent shell: ")
  (let ((buffers (seq-remove #'agent-shell-consult--live-p
                             (agent-shell-buffers))))
    (if (null buffers)
        (message "No killed agent-shell buffers")
      (when (yes-or-no-p (format "Delete %d killed agent-shell buffers? "
                                 (length buffers)))
        (mapc #'kill-buffer buffers)))))

(defmacro agent-shell-consult--action (name function)
  "Define Embark action NAME that calls FUNCTION in its candidate."
  `(defun ,name (candidate)
     ,(format "Run `%s' for CANDIDATE." function)
     (interactive "sAgent shell: ")
     (agent-shell-consult--call candidate #',function)))

(agent-shell-consult--action agent-shell-consult-action-restart agent-shell-restart)
(agent-shell-consult--action agent-shell-consult-action-set-mode agent-shell-set-session-mode)
(agent-shell-consult--action agent-shell-consult-action-set-model agent-shell-set-session-model)
(agent-shell-consult--action agent-shell-consult-action-interrupt agent-shell-interrupt)
(agent-shell-consult--action agent-shell-consult-action-view-traffic agent-shell-view-traffic)
(agent-shell-consult--action agent-shell-consult-action-toggle-logging agent-shell-toggle-logging)

(defvar agent-shell-consult-embark-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("RET" . agent-shell-consult-action-switch)
                       ("k" . agent-shell-consult-action-kill)
                       ("c" . agent-shell-consult-action-new)
                       ("r" . agent-shell-consult-action-restart)
                       ("d" . agent-shell-consult-action-delete-killed)
                       ("m" . agent-shell-consult-action-set-mode)
                       ("M" . agent-shell-consult-action-set-model)
                       ("C-c C-c" . agent-shell-consult-action-interrupt)
                       ("t" . agent-shell-consult-action-view-traffic)
                       ("l" . agent-shell-consult-action-toggle-logging)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map)
  "Embark actions for `agent-shell-consult' candidates.")

(with-eval-after-load 'embark
  (add-to-list 'embark-keymap-alist
               '(agent-shell-consult-buffer . agent-shell-consult-embark-map)))

;;;###autoload
(defun agent-shell-consult ()
  "Switch agent-shell buffers with Consult metadata when available."
  (interactive)
  (let ((buffers (agent-shell-consult--buffers)))
    (unless buffers (user-error "No agent-shell buffers"))
    (switch-to-buffer
     (if (require 'consult nil t)
         (agent-shell-consult--read buffers)
       (agent-shell--read-shell-buffer
        :prompt "Switch to agent-shell buffer: " :buffers buffers)))))

(provide 'agent-shell-consult)

;;; agent-shell-consult.el ends here
