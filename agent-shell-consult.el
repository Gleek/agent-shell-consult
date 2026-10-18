;;; agent-shell-consult.el --- Consult UI for agent-shell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar
;; Version: 0.3.0
;; Package-Requires: ((emacs "28.1") (agent-shell "0.83.4") (acp "0.18.1"))
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
(declare-function agent-shell--input "agent-shell")
(defvar embark-keymap-alist)
(defvar embark-transformer-alist)
(defvar embark-default-action-overrides)
(defvar consult--narrow)
(declare-function agent-shell-attention--pending-live-entries "agent-shell-attention")
(declare-function agent-shell-attention--pending-entry-permission-p "agent-shell-attention")
(declare-function agent-shell-attention--permission-pending-p "agent-shell-attention")
(declare-function agent-shell-attention--clear-buffer "agent-shell-attention")
(declare-function agent-shell-attention--maybe-clear-current "agent-shell-attention")

(defgroup agent-shell-consult nil
  "Consult interface for Agent Shell."
  :group 'agent-shell)

(defcustom agent-shell-consult-session-agents nil
  "Agents whose saved sessions to include after inactive buffers.
Each entry is an Agent Shell config maker function or a config alist.
For example, use `agent-shell-anthropic-make-claude-code-config' and
`agent-shell-openai-make-codex-config' to browse Claude and Codex.
Only agents advertising session listing and loading or resuming are used.
Nil disables saved session discovery.  Requires acp.el to support
`acp-make-session-list-request' without a working directory."
  :type '(repeat (choice function (alist :key-type symbol :value-type sexp)))
  :group 'agent-shell-consult)

(defcustom agent-shell-consult-session-timeout 30
  "Seconds allowed for each agent to initialize and list saved sessions."
  :type 'natnum
  :group 'agent-shell-consult)

(defcustom agent-shell-consult-session-cache-ttl 60
  "Seconds before an agent's cached session list needs refreshing.
Cached sessions remain available until replaced.  Opening the picker
shows them immediately and refreshes expired lists asynchronously.
Zero refreshes on every opening.  Buffer filtering and displayed ages
are always recomputed.  Use `agent-shell-consult-refresh-sessions' to
discard cached lists and refresh early."
  :type 'natnum
  :group 'agent-shell-consult)

(defvar agent-shell-consult--session-cache (make-hash-table :test #'equal)
  "Raw session lists keyed by agent config, remote host, and page limit.
Values are (FETCH-TIME . SESSIONS), including empty session lists.")

(defvar agent-shell-consult--session-capabilities (make-hash-table :test #'equal)
  "Advertised session capabilities, keyed like the session cache.")

(defun agent-shell-consult--cache-key (config)
  "Return the session discovery cache key for CONFIG."
  (list config (file-remote-p default-directory) agent-shell-session-list-page-limit))

(defcustom agent-shell-consult-resume-commands
  '((codex "codex" "resume") (claude-code "claude" "--resume"))
  "Native CLI resume commands by Agent Shell config identifier.
Each value is a list of command arguments.  The session ID is appended.
Used only for copying commands, never for executing them."
  :type '(alist :key-type symbol :value-type (repeat string))
  :group 'agent-shell-consult)

(defvar agent-shell-consult--saved-entries nil
  "Saved entries from the latest picker, for Embark's plain-text targets.")

(defun agent-shell-consult--saved-entry (candidate)
  "Return CANDIDATE's saved session data, including for Embark targets."
  (or (get-text-property 0 'agent-shell-consult-session candidate)
      (cdr (assoc-string candidate agent-shell-consult--saved-entries))))

(defun agent-shell-consult--fetch-sessions (config on-success on-failure)
  "Fetch saved sessions for CONFIG asynchronously.
Call ON-SUCCESS with sessions, or ON-FAILURE with a reason string.
Return a function that cancels discovery and releases its resources."
  (let ((buffer (generate-new-buffer " *agent-shell-consult-sessions*"))
        (key (agent-shell-consult--cache-key config))
        client timer finished)
    (cl-labels
        ((cleanup ()
           (setq finished t)
           (when timer (cancel-timer timer))
           (when client (acp-shutdown :client client))
           (when (buffer-live-p buffer) (kill-buffer buffer)))
         (fail (reason &rest _)
           (unless finished
             (cleanup)
             (funcall on-failure
                      (if (stringp reason) reason
                        (or (map-elt reason 'message) (format "%s" reason))))))
         (succeed (sessions)
           (unless finished
             (cleanup)
             (funcall on-success sessions)))
         (list-sessions ()
           (condition-case err
               (agent-shell--list-sessions
                :state (list (cons :client client)) :buffer buffer
                :on-success #'succeed :on-failure #'fail)
             (error (fail (error-message-string err))))))
      (condition-case err
          (progn
            (with-current-buffer buffer
              (setq client (funcall (map-elt config :client-maker) buffer)))
            (setq timer (run-at-time agent-shell-consult-session-timeout nil
                                     #'fail "Session discovery timed out"))
            (acp-send-request
             :client client
             :request (acp-make-initialize-request :protocol-version 1)
             :on-failure #'fail
             :on-success
             (lambda (response)
               (unless finished
                 (let* ((capabilities (map-elt response 'agentCapabilities))
                        (sessions (or (map-elt response 'sessionCapabilities)
                                      (map-elt capabilities 'sessionCapabilities))))
                   (puthash key sessions agent-shell-consult--session-capabilities)
                   (cond
                    ((not (assq 'list sessions))
                     (fail "Agent does not support session listing"))
                    ((not (or (eq t (map-elt capabilities 'loadSession))
                              (assq 'resume sessions)))
                     (fail "Agent does not support restoring sessions"))
                    ((map-elt config :needs-authentication)
                     (condition-case err
                         (acp-send-request
                          :client client
                          :request (funcall (map-elt config :authenticate-request-maker))
                          :on-success (lambda (_) (list-sessions))
                          :on-failure #'fail)
                       (error (fail (error-message-string err)))))
                    (t (list-sessions))))))))
        (error (fail (error-message-string err))))
      #'cleanup)))

(defun agent-shell-consult--sessions (config on-success on-failure)
  "Deliver cached sessions for CONFIG, refreshing expired lists asynchronously.
ON-SUCCESS may run twice: immediately with cached sessions, then with
fresh sessions.  ON-FAILURE and the cancellation function are as in
`agent-shell-consult--fetch-sessions'."
  (let* ((key (agent-shell-consult--cache-key config))
         (cached (gethash key agent-shell-consult--session-cache)))
    (when cached (funcall on-success (cdr cached)))
    (if (and cached
             (< (- (float-time) (car cached)) agent-shell-consult-session-cache-ttl))
        #'ignore
      (agent-shell-consult--fetch-sessions
       config
       (lambda (sessions)
         (puthash key (cons (float-time) sessions) agent-shell-consult--session-cache)
         (funcall on-success sessions))
       on-failure))))

(defun agent-shell-consult--session-key (config id)
  "Identify session ID belonging to CONFIG."
  (cons (map-elt config :identifier) id))

(defun agent-shell-consult--session-entries (sources)
  "Build saved session entries from SOURCES, excluding existing buffers.
Each source is a cons of an agent config and its session list."
  (let ((seen (make-hash-table :test #'equal)) entries)
    (dolist (buffer (agent-shell-buffers))
      (with-current-buffer buffer
        (puthash (agent-shell-consult--session-key
                  (map-elt agent-shell--state :agent-config)
                  (map-nested-elt agent-shell--state '(:session :id)))
                 t seen)))
    (dolist (source sources)
      (let* ((config (car source))
             (agent (or (map-elt config :mode-line-name)
                        (symbol-name (map-elt config :identifier))))
             (icon (when agent-shell-show-config-icons
                     (agent-shell--config-icon :config config))))
        (dolist (session (cdr source))
          (let* ((id (map-elt session 'sessionId))
                 (cwd (map-elt session 'cwd))
                 (key (agent-shell-consult--session-key config id)))
            (when (and (stringp id) (not (string-empty-p id))
                       (stringp cwd) (not (string-empty-p cwd))
                       (not (gethash key seen)))
              (puthash key t seen)
              (let* ((project (file-name-nondirectory (directory-file-name cwd)))
                     (title (string-trim (car (split-string
                                               (or (map-elt session 'title) "") "\n"))))
                     (name (truncate-string-to-width
                            (if (string-empty-p title) "Untitled session" title)
                            50 nil nil "..."))
                     (updated (ignore-errors (date-to-time (map-elt session 'updatedAt))))
                     (entry (list :config config :session session :name name
                                  :supports-fork
                                  (and (assq 'fork
                                             (gethash (agent-shell-consult--cache-key config)
                                                      agent-shell-consult--session-capabilities))
                                       t)
                                  :icon icon :project project :status ""
                                  :age (when updated
                                         (propertize
                                          (agent-shell-consult--duration updated (current-time))
                                          'face 'shadow))
                                  :updated (if updated (float-time updated) 0)
                                  :title ""))
                     (candidate (concat title " " agent " " cwd " " id)))
                (add-text-properties
                 0 (length candidate)
                 (list 'display (propertize name 'face 'agent-shell-session-title
                                            'agent-shell-consult-session entry)
                       'agent-shell-consult-session entry
                       'agent-shell-consult-project project
                       'agent-shell-consult-group "Saved sessions")
                 candidate)
                (push (cons candidate entry) entries)))))))
    (sort entries (lambda (a b) (> (plist-get (cdr a) :updated)
                                  (plist-get (cdr b) :updated))))))

(defun agent-shell-consult--open (entry &optional fork)
  "Return ENTRY's buffer, restoring a saved session if necessary.
When FORK is non-nil, create a fork instead of resuming the session."
  (unless entry (user-error "Session is no longer available"))
  (or (when-let* ((buffer (plist-get entry :buffer)))
        (unless (buffer-live-p buffer)
          (user-error "Agent-shell buffer no longer exists"))
        buffer)
      (let* ((config (plist-get entry :config))
             (session (plist-get entry :session))
             (id (map-elt session 'sessionId))
             (existing
              (seq-find
               (lambda (buffer)
                 (with-current-buffer buffer
                   (equal (agent-shell-consult--session-key config id)
                          (agent-shell-consult--session-key
                           (map-elt agent-shell--state :agent-config)
                           (map-nested-elt agent-shell--state '(:session :id))))))
               (agent-shell-buffers))))
        (or (and (not fork) existing)
            (let* ((cwd (file-name-as-directory (map-elt session 'cwd)))
                   (default-directory cwd))
              (unless (file-directory-p default-directory)
                (user-error "Session directory no longer exists: %s" default-directory))
              (let ((buffer
                     (let ((agent-shell-cwd-function (lambda () cwd)))
                       (if fork
                           (agent-shell--start :config config :fork-session-id id
                                               :new-session t)
                         (agent-shell-start :config config :session-id id)))))
                (with-current-buffer buffer
                  (setq-local agent-shell-cwd-function (lambda () cwd)))
                buffer))))))

(defun agent-shell-consult--unread-p (buffer)
  "Return non-nil when attention tracks unread output for BUFFER.
Permission requests are not unread output.  Attention is optional."
  (when (seq-every-p
         #'fboundp
         '(agent-shell-attention--pending-live-entries
           agent-shell-attention--pending-entry-permission-p
           agent-shell-attention--permission-pending-p
           agent-shell-attention--clear-buffer))
    (when-let* ((entry (alist-get buffer
                                 (agent-shell-attention--pending-live-entries))))
      (and (not (agent-shell-attention--pending-entry-permission-p entry))
           (not (agent-shell-attention--permission-pending-p buffer))))))

(defun agent-shell-consult--buffer (candidate)
  "Return the live agent-shell buffer stored on CANDIDATE."
  (when (agent-shell-consult--saved-entry candidate)
    (user-error "Saved session has no buffer; use RET to resume it"))
  (let* ((buffer (get-text-property 0 'agent-shell-consult-buffer candidate))
         (matches
          (unless (buffer-live-p buffer)
            (seq-keep
             (lambda (entry)
               (when (or (equal candidate (car entry))
                         (equal candidate (plist-get (cdr entry) :name)))
                 (plist-get (cdr entry) :buffer)))
             (agent-shell-consult--entries (agent-shell-buffers))))))
    (when (= (length matches) 1)
      (setq buffer (car matches)))
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
    (let* ((status (if (agent-shell-consult--live-p buffer)
                       (agent-shell-status :shell-buffer buffer)
                     'killed))
           (kind (if (eq status 'ready)
                     (cond ((not (map-elt agent-shell--state :initialized))
                            'starting)
                           ((not (map-nested-elt agent-shell--state
                                                 '(:session :id)))
                            'no-session)
                           ((agent-shell--input) 'draft)
                           (t 'ready))
                   status)))
      (list
       (pcase kind
         ('blocked (propertize "Waiting" 'face 'agent-shell-error))
         ('busy (propertize "Working" 'face 'agent-shell-warning))
         ('killed (propertize "Killed" 'face 'agent-shell-error))
         ('starting (propertize "Starting..." 'face 'shadow))
         ('no-session (propertize "No Session" 'face 'shadow))
         ('draft (propertize "Draft" 'face 'agent-shell-error))
         ('ready (propertize "Ready" 'face 'agent-shell-success))
         (_ (propertize "Unknown" 'face 'shadow)))
       (when-let* (((eq status 'ready))
                   (last-activity (map-elt agent-shell--state
                                           :last-activity-time)))
         (propertize (agent-shell-consult--duration last-activity now)
                     'face 'shadow))
       kind))))

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
         (pcase-let* ((`(,status ,age ,status-kind)
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
                                    "\n"))))
                      (project (agent-shell-consult--project buffer))
                      (last-activity (map-elt agent-shell--state :last-activity-time))
                      (group (if (or (memq status-kind '(busy blocked starting draft))
                                     (and (eq status-kind 'ready)
                                          last-activity
                                          (< (float-time (time-subtract now last-activity))
                                             86400)))
                                 "Active"
                               "Inactive"))
                      (candidate (concat name " " project
                                         (unless (string-empty-p title)
                                           (concat " " title)))))
           ;; Keep PROJECT and TITLE in the candidate so completion styles can
           ;; match them, while displaying only NAME; both are annotations.
           (put-text-property
            0 (length candidate) 'display
            (propertize name
                        'face 'agent-shell-buffer-name
                        'agent-shell-consult-buffer buffer)
            candidate)
           (put-text-property 0 (length candidate)
                              'agent-shell-consult-buffer buffer candidate)
           (put-text-property 0 (length candidate)
                              'agent-shell-consult-project project candidate)
           (put-text-property 0 (length candidate)
                              'agent-shell-consult-status status-kind candidate)
           (put-text-property 0 (length candidate)
                              'agent-shell-consult-group group candidate)
           (cons candidate
                 (list :buffer buffer
                       :name name
                       :icon (when agent-shell-show-config-icons
                               (agent-shell--config-icon :config config))
                       :project project
                       :status status
                       :age age
                       :title (truncate-string-to-width title 50 nil nil "..."))))))
     buffers)))

(defun agent-shell-consult--narrow (project)
  "Return Consult narrowing configuration for the current PROJECT."
  (let ((statuses '((?w . busy) (?b . blocked) (?r . ready) (?d . draft)
                    (?s . starting) (?n . no-session) (?k . killed))))
    (list :predicate
          (lambda (candidate)
            (pcase consult--narrow
              (?p (equal (get-text-property 0 'agent-shell-consult-project candidate)
                         project))
              (?h (get-text-property 0 'agent-shell-consult-session candidate))
              (_ (eq (get-text-property 0 'agent-shell-consult-status candidate)
                     (alist-get consult--narrow statuses)))))
          :keys '((?p . "Current project")
                  (?h . "Saved sessions")
                  (?w . "Working")
                  (?b . "Waiting")
                  (?r . "Ready")
                  (?d . "Draft")
                  (?s . "Starting")
                  (?n . "No session")
                  (?k . "Killed")))))

(defun agent-shell-consult--entry (candidate entries)
  "Return CANDIDATE's data from ENTRIES."
  (cdr (assoc-string candidate entries)))

(defun agent-shell-consult--affix (candidate entries widths)
  "Add metadata to CANDIDATE using ENTRIES and column WIDTHS."
  (let* ((entry (agent-shell-consult--entry candidate entries))
         (padding (+ 2 (- (nth 0 widths)
                          (string-width (plist-get entry :name)))))
         (project (plist-get entry :project))
         (status (concat (plist-get entry :status)
                         (when (and (plist-get entry :buffer)
                                    (agent-shell-consult--unread-p
                                     (plist-get entry :buffer)))
                           (propertize " ●" 'face 'agent-shell-success))))
         (age (or (plist-get entry :age) ""))
         (title (plist-get entry :title)))
    (list candidate
          (if-let* ((icon (plist-get entry :icon))) (concat icon " ") "")
          (concat (make-string padding ?\s)
                  (string-pad (propertize project 'face 'shadow) (nth 1 widths))
                  "  " status
                  (make-string (max 0 (- (nth 2 widths) (string-width status))) ?\s)
                  "  " (string-pad age (nth 3 widths))
                  (unless (string-empty-p title)
                    (concat "  " (propertize title 'face
                                              'agent-shell-session-title)))))))

(defun agent-shell-consult--preview-state (entries)
  "Return a Consult preview state using the ENTRIES getter function.
Consult's buffer state treats the candidate text as a buffer name.  Our
candidate text may omit the common agent prefix, so translate it back to the
stored buffer's full name before delegating to Consult."
  (let ((state (consult--buffer-state)))
    (lambda (action candidate)
      (let ((buffer (when candidate
                      (plist-get (agent-shell-consult--entry candidate (funcall entries))
                                 :buffer))))
        (prog1 (funcall state action
                        (when (buffer-live-p buffer) (buffer-name buffer)))
          (when (and (eq action 'return)
                     (buffer-live-p buffer)
                     (get-buffer-window buffer t)
                     (agent-shell-consult--unread-p buffer))
            (agent-shell-attention--clear-buffer buffer)))))))

(defun agent-shell-consult--widths (entries)
  "Return annotation column widths for ENTRIES."
  (mapcar (lambda (key)
            (apply #'max 0
                   (mapcar (lambda (entry)
                             (+ (if (eq key :status) 2 0)
                                (string-width (or (plist-get (cdr entry) key) ""))))
                           entries)))
          '(:name :project :status :age)))

(defun agent-shell-consult--read (buffers)
  "Read BUFFERS and configured saved sessions with Consult."
  (let* ((project (agent-shell-consult--project (current-buffer)))
         (buffer-entries
          (cl-stable-sort
           (agent-shell-consult--entries buffers)
           (lambda (a b)
             (and (equal (get-text-property 0 'agent-shell-consult-group (car a)) "Active")
                  (equal (get-text-property 0 'agent-shell-consult-group (car b)) "Inactive")))))
         (entries buffer-entries)
         (widths (agent-shell-consult--widths entries))
         (sources nil)
         (collection
          (lambda (sink)
            (let (cleanups active)
              (lambda (action)
                (pcase action
                  ('setup
                   (setq active t)
                   (setq agent-shell-consult--saved-entries nil)
                   (funcall sink 'setup)
                   (when entries (funcall sink (mapcar #'car entries)))
                   (dolist (designator agent-shell-consult-session-agents)
                     (condition-case err
                         (let* ((config (if (functionp designator)
                                            (funcall designator) designator))
                                (label (map-elt config :identifier)))
                           (push
                            (agent-shell-consult--sessions
                             config
                             (lambda (sessions)
                               (when active
                                 (setf (alist-get config sources nil nil #'equal) sessions)
                                 (setq agent-shell-consult--saved-entries
                                       (agent-shell-consult--session-entries sources)
                                       entries (append buffer-entries agent-shell-consult--saved-entries)
                                       widths (agent-shell-consult--widths entries))
                                 (funcall sink 'flush)
                                 (when entries (funcall sink (mapcar #'car entries)))
                                 (funcall sink 'refresh)))
                             (lambda (reason)
                               (when active
                                 (message "Saved sessions (%s): %s" label reason))))
                            cleanups))
                       (error (message "Saved sessions: %s" (error-message-string err))))))
                  ('destroy
                   (setq active nil)
                   (mapc #'funcall cleanups)
                   (funcall sink 'destroy))
                  (_ (funcall sink action)))))))
         ;; Preview must not clear unread output until selection is confirmed.
         (buffer-list-update-hook
          (remq #'agent-shell-attention--maybe-clear-current
                buffer-list-update-hook))
         (selection
          (consult--read (if agent-shell-consult-session-agents
                             collection (mapcar #'car entries))
                         :async-wrap #'identity
                         :prompt "Switch to agent shell: "
                         :require-match t
                         :category 'agent-shell-consult-buffer
                         :sort nil
                         :group (lambda (candidate transform)
                                  (if transform candidate
                                    (get-text-property 0 'agent-shell-consult-group candidate)))
                         :narrow (agent-shell-consult--narrow project)
                         :annotate (lambda (candidate)
                                     (agent-shell-consult--affix candidate entries widths))
                         :state (agent-shell-consult--preview-state (lambda () entries))
                         :preview-key 'any)))
    (agent-shell-consult--open (agent-shell-consult--entry selection entries))))

(defun agent-shell-consult--call (candidate function)
  "Call FUNCTION interactively in CANDIDATE's agent-shell buffer."
  (with-current-buffer (agent-shell-consult--buffer candidate)
    (call-interactively function)))

(defun agent-shell-consult-action-switch (candidate)
  "Switch to CANDIDATE."
  (interactive "sAgent shell: ")
  (switch-to-buffer
   (if-let* ((entry (agent-shell-consult--saved-entry candidate)))
       (agent-shell-consult--open entry)
     (agent-shell-consult--buffer candidate))))

(defun agent-shell-consult-action-resume (candidate)
  "Resume CANDIDATE's saved session."
  (interactive "sSaved session: ")
  (agent-shell-consult-action-switch candidate))

(defun agent-shell-consult-action-fork (candidate)
  "Fork CANDIDATE's conversation into a separate Agent Shell buffer."
  (interactive "sAgent session: ")
  (if-let* ((entry (agent-shell-consult--saved-entry candidate)))
      (progn
        (unless (plist-get entry :supports-fork)
          (user-error "Agent does not advertise session forking; refresh sessions to recheck"))
        (switch-to-buffer (agent-shell-consult--open entry t)))
    (agent-shell-consult--call candidate #'agent-shell-fork)))

(defun agent-shell-consult--saved-session (candidate)
  "Return CANDIDATE's saved ACP session, or signal a user error."
  (or (plist-get (agent-shell-consult--saved-entry candidate) :session)
      (user-error "Saved session is no longer available")))

(defun agent-shell-consult-action-copy-session-id (candidate)
  "Copy CANDIDATE's session ID to the kill ring."
  (interactive "sSaved session: ")
  (kill-new (map-elt (agent-shell-consult--saved-session candidate) 'sessionId))
  (message "Session ID copied"))

(defun agent-shell-consult-action-open-directory (candidate)
  "Open CANDIDATE's working directory in Dired."
  (interactive "sSaved session: ")
  (dired (map-elt (agent-shell-consult--saved-session candidate) 'cwd)))

(defun agent-shell-consult-action-copy-resume-command (candidate)
  "Copy a native CLI command to resume CANDIDATE in its directory."
  (interactive "sSaved session: ")
  (let* ((session (agent-shell-consult--saved-session candidate))
         (config (plist-get (agent-shell-consult--saved-entry candidate) :config))
         (identifier (map-elt config :identifier))
         (command (alist-get identifier agent-shell-consult-resume-commands)))
    (unless command
      (user-error "No resume command configured for %s" identifier))
    (kill-new (concat "cd -- "
                      (shell-quote-argument (file-local-name (map-elt session 'cwd)))
                      " && "
                      (mapconcat #'shell-quote-argument
                                 (append command (list (map-elt session 'sessionId))) " ")))
    (message "Resume command copied")))

(defun agent-shell-consult-action-view-saved-transcript (candidate)
  "View CANDIDATE's existing Agent Shell transcript without resuming."
  (interactive "sSaved session: ")
  (let* ((session (agent-shell-consult--saved-session candidate))
         (cwd (file-name-as-directory (map-elt session 'cwd)))
         (default-directory cwd)
         (agent-shell-cwd-function (lambda () cwd))
         (directory (funcall agent-shell-dot-subdir-function "transcripts"))
         (pattern (concat "^\\(?:session_id: \\|\\*\\*Session ID:\\*\\* \\)\\\"?"
                          (regexp-quote (map-elt session 'sessionId)) "\\\"?[ \t]*$"))
         (file
          (when (file-directory-p directory)
            (seq-find
             (lambda (path)
               (condition-case nil
                   (with-temp-buffer
                     (insert-file-contents path nil 0 4096)
                     (re-search-forward pattern nil t))
                 (file-error nil)))
             (reverse (directory-files directory t "\\.md\\'"))))))
    (unless file (user-error "No Agent Shell transcript found for this session"))
    (view-file file)))

(defun agent-shell-consult-action-kill (candidate)
  "Kill CANDIDATE's buffer."
  (interactive "sAgent shell: ")
  (kill-buffer (agent-shell-consult--buffer candidate)))

(defun agent-shell-consult-action-kill-agent (candidate)
  "Stop CANDIDATE's agent process."
  (interactive "sAgent shell: ")
  (when (yes-or-no-p (format "Kill agent-shell process in %s? " candidate))
    (agent-shell-consult--call candidate #'comint-send-eof)))

(defmacro agent-shell-consult--action (name function)
  "Define Embark action NAME that calls FUNCTION in its candidate."
  `(defun ,name (candidate)
     ,(format "Run `%s' for CANDIDATE." function)
     (interactive "sAgent shell: ")
     (agent-shell-consult--call candidate #',function)))

(agent-shell-consult--action agent-shell-consult-action-restart agent-shell-restart)
(agent-shell-consult--action agent-shell-consult-action-reload agent-shell-reload)
(agent-shell-consult--action agent-shell-consult-action-set-mode agent-shell-set-session-mode)
(agent-shell-consult--action agent-shell-consult-action-set-model agent-shell-set-session-model)
(agent-shell-consult--action agent-shell-consult-action-interrupt agent-shell-interrupt)
(agent-shell-consult--action agent-shell-consult-action-open-transcript agent-shell-open-transcript)
(agent-shell-consult--action agent-shell-consult-action-view-traffic agent-shell-view-traffic)
(agent-shell-consult--action agent-shell-consult-action-toggle-logging agent-shell-toggle-logging)

(defvar agent-shell-consult-embark-map
  (let ((map (make-sparse-keymap)))
    (dolist (binding '(("RET" . agent-shell-consult-action-switch)
                       ("T" . agent-shell-consult-action-view-traffic)
                       ("L" . agent-shell-consult-action-toggle-logging)
                       ("t" . agent-shell-consult-action-open-transcript)
                       ("f" . agent-shell-consult-action-fork)
                       ("i" . agent-shell-consult-action-interrupt)
                       ("l" . agent-shell-consult-action-set-model)
                       ("m" . agent-shell-consult-action-set-mode)
                       ("R" . agent-shell-consult-action-reload)
                       ("r" . agent-shell-consult-action-restart)
                       ("K" . agent-shell-consult-action-kill-agent)
                       ("k" . agent-shell-consult-action-kill)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map)
  "Embark actions for existing Agent Shell buffers.")

(defvar agent-shell-consult-session-embark-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-shell-consult-action-resume)
    (define-key map (kbd "f") #'agent-shell-consult-action-fork)
    (define-key map (kbd "w") #'agent-shell-consult-action-copy-session-id)
    (define-key map (kbd "d") #'agent-shell-consult-action-open-directory)
    (define-key map (kbd "c") #'agent-shell-consult-action-copy-resume-command)
    (define-key map (kbd "t") #'agent-shell-consult-action-view-saved-transcript)
    map)
  "Embark actions for saved Agent Shell sessions.")

(defun agent-shell-consult--embark-target (type candidate)
  "Distinguish saved sessions from buffer targets of TYPE for CANDIDATE."
  (cons (if (agent-shell-consult--saved-entry candidate)
            'agent-shell-consult-session type)
        candidate))

(with-eval-after-load 'embark
  (add-to-list 'embark-keymap-alist
               '(agent-shell-consult-buffer . agent-shell-consult-embark-map))
  (add-to-list 'embark-keymap-alist
               '(agent-shell-consult-session . agent-shell-consult-session-embark-map))
  (add-to-list 'embark-transformer-alist
               '(agent-shell-consult-buffer . agent-shell-consult--embark-target))
  (add-to-list 'embark-default-action-overrides
               '(agent-shell-consult-session . agent-shell-consult-action-resume)))

;;;###autoload
(defun agent-shell-consult-refresh-sessions ()
  "Refresh saved sessions and open the Agent Shell picker."
  (interactive)
  (agent-shell-consult t))

;;;###autoload
(defun agent-shell-consult (&optional refresh)
  "Switch Agent Shell buffers or resume configured saved sessions.
With prefix argument REFRESH, discard cached session lists first."
  (interactive "P")
  (when refresh
    (clrhash agent-shell-consult--session-cache)
    (clrhash agent-shell-consult--session-capabilities))
  (let ((buffers (agent-shell-consult--buffers)))
    (if (require 'consult nil t)
        (progn
          (unless (or buffers agent-shell-consult-session-agents)
            (user-error "No agent-shell buffers or configured session agents"))
          (switch-to-buffer (agent-shell-consult--read buffers)))
      (unless buffers (user-error "No agent-shell buffers"))
      (switch-to-buffer
       (agent-shell--read-shell-buffer
        :prompt "Switch to agent-shell buffer: " :buffers buffers)))))

(provide 'agent-shell-consult)

;;; agent-shell-consult.el ends here
