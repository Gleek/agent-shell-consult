;;; agent-shell-switch.el --- Project-grouped agent-shell switcher -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Umar

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this package.  If not, see <https://www.gnu.org/licenses/>.

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (agent-shell "0.73.2"))
;; Keywords: convenience, processes, tools
;; URL: https://github.com/Gleek/agent-shell-switch

;;; Commentary:
;;
;; Select an agent-shell buffer with `completing-read'.  Candidates are grouped
;; by project and show a snapshot of the current agent status.

;;; Code:

(require 'agent-shell)
(require 'subr-x)

(declare-function consult--buffer-state "consult")
(declare-function consult--read "consult")

(defun agent-shell-switch--duration (since now)
  "Format the elapsed time between SINCE and NOW."
  (let* ((seconds (max 0 (floor (float-time (time-subtract now since)))))
         (days (/ seconds 86400))
         (hours (/ (% seconds 86400) 3600))
         (minutes (/ (% seconds 3600) 60)))
    (cond
     ((> days 0) (format "%dd %dh" days hours))
     ((> hours 0) (format "%dh %dm" hours minutes))
     ((> minutes 0) (format "%dm" minutes))
     (t "<1m"))))

(defun agent-shell-switch--project (buffer)
  "Return BUFFER's project name."
  (with-current-buffer buffer
    (if (fboundp 'agent-shell--project-name)
        (agent-shell--project-name)
      (file-name-nondirectory
       (directory-file-name (expand-file-name default-directory))))))

(defun agent-shell-switch--status (buffer now)
  "Return BUFFER's status label and ready age at NOW."
  (with-current-buffer buffer
    (let* ((state agent-shell--state)
           (status (condition-case nil
                       (agent-shell-status :shell-buffer buffer)
                     (error 'killed))))
      (pcase status
        ('blocked (list (propertize "Waiting" 'face 'font-lock-keyword-face)
                        nil))
        ('busy (list (propertize "Working" 'face 'warning) nil))
        ('killed (list (propertize "Killed" 'face 'error) nil))
        ('ready
         (cond
          ((not (map-elt state :initialized))
           (list (propertize "Starting..." 'face 'shadow) nil))
          ((not (map-nested-elt state '(:session :id)))
           (list (propertize "No Session" 'face 'shadow) nil))
          (t
           (list (propertize "Ready" 'face 'success)
                 (when-let* ((last-activity
                              (map-elt state :last-activity-time)))
                   (propertize (agent-shell-switch--duration last-activity now)
                               'face 'shadow))))))
        (_ (list (propertize "Unknown" 'face 'shadow) nil))))))

(defun agent-shell-switch--entry (candidate entries)
  "Return CANDIDATE's entry from ENTRIES."
  (cdr (assoc-string candidate entries)))

(defun agent-shell-switch--affix (candidate entries name-width status-width)
  "Add aligned status columns to CANDIDATE from ENTRIES.
NAME-WIDTH and STATUS-WIDTH are the widest display widths in their columns."
  (let* ((entry (agent-shell-switch--entry candidate entries))
         (status (plist-get entry :status))
         (age (plist-get entry :age))
         (padding (+ 2 (- name-width (string-width candidate)))))
    (list candidate ""
          (concat (make-string padding ?\s)
                  (string-pad status status-width)
                  (when age (concat "  " age))))))

(defun agent-shell-switch--affixation
    (candidates entries name-width status-width)
  "Affix CANDIDATES using ENTRIES, NAME-WIDTH, and STATUS-WIDTH."
  (mapcar (lambda (candidate)
            (agent-shell-switch--affix
             candidate entries name-width status-width))
          candidates))

;;;###autoload
(defun agent-shell-switch ()
  "Select an agent-shell buffer grouped by project."
  (interactive)
  (let* ((buffers (seq-filter #'buffer-live-p (agent-shell-buffers)))
         (_ (unless buffers (user-error "No agent-shell buffers")))
         (now (current-time))
         (entries
          (mapcar
           (lambda (buffer)
             (pcase-let ((`(,status ,age)
                          (agent-shell-switch--status buffer now)))
               (cons (buffer-name buffer)
                     (list :buffer buffer
                           :project (agent-shell-switch--project buffer)
                           :status status
                           :age age))))
           buffers))
         (entries
          (sort entries
                (lambda (a b)
                  (let ((project-a (plist-get (cdr a) :project))
                        (project-b (plist-get (cdr b) :project)))
                    (if (equal project-a project-b)
                        (string-lessp (car a) (car b))
                      (string-lessp project-a project-b))))))
         (candidates (mapcar #'car entries))
         (name-width (apply #'max (mapcar #'string-width candidates)))
         (status-width
          (apply #'max
                 (mapcar (lambda (entry)
                           (string-width (plist-get (cdr entry) :status)))
                         entries)))
         (affixation
          (lambda (items)
            (agent-shell-switch--affixation
             items entries name-width status-width)))
         (group
          (lambda (candidate transform)
            (if transform
                candidate
              (plist-get (agent-shell-switch--entry candidate entries)
                         :project))))
         (table
          (completion-table-with-metadata
           candidates
           `((category . agent-shell-buffer)
             (display-sort-function . identity)
             (group-function . ,group)
             (affixation-function . ,affixation))))
         (completion-styles (cons 'substring completion-styles))
         (selection
          (if (require 'consult nil t)
              (consult--read
               candidates
               :prompt "Switch to agent shell: "
               :require-match t
               :category 'agent-shell-buffer
               :sort nil
               :group group
               :annotate
               (lambda (candidate)
                 (agent-shell-switch--affix
                  candidate entries name-width status-width))
               :state (consult--buffer-state)
               :preview-key 'any)
            (completing-read "Switch to agent shell: " table nil t)))
         (buffer (plist-get (agent-shell-switch--entry selection entries)
                            :buffer)))
    (unless (buffer-live-p buffer)
      (user-error "Agent-shell buffer no longer exists"))
    (switch-to-buffer buffer)))

(provide 'agent-shell-switch)

;;; agent-shell-switch.el ends here
