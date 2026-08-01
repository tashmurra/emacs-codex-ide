;;; codex-ide-plan.el --- Structured Codex plan updates -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Duncan Gillis

;;; Commentary:

;; Normalize and format structured `turn/plan/updated' payloads.  Transcript
;; placement and live marker management remain in `codex-ide-transcript.el'.

;;; Code:

(require 'subr-x)

(defgroup codex-ide-plan nil
  "Structured Codex plan update presentation."
  :group 'codex-ide)

(defface codex-ide-plan-heading-face
  '((t :inherit codex-ide-item-summary-face :weight bold))
  "Face used for structured plan headings."
  :group 'codex-ide-plan)

(defface codex-ide-plan-explanation-face
  '((t :inherit codex-ide-item-detail-face))
  "Face used for structured plan explanations."
  :group 'codex-ide-plan)

(defface codex-ide-plan-completed-face
  '((t :inherit shadow :strike-through t))
  "Face used for completed structured plan steps."
  :group 'codex-ide-plan)

(defface codex-ide-plan-in-progress-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face used for in-progress structured plan steps."
  :group 'codex-ide-plan)

(defface codex-ide-plan-pending-face
  '((t :inherit codex-ide-item-detail-face))
  "Face used for pending structured plan steps."
  :group 'codex-ide-plan)

(defun codex-ide-plan--sequence-list (value)
  "Return VALUE as a list when it is a list or vector; otherwise nil."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t nil)))

(defun codex-ide-plan--normalize-status (value)
  "Return the normalized structured plan status for VALUE."
  (pcase (downcase (format "%s" (or value "pending")))
    ("completed" 'completed)
    ("inprogress" 'in-progress)
    ("pending" 'pending)
    (_ 'pending)))

(defun codex-ide-plan--normalize-step (entry)
  "Return normalized structured plan ENTRY, or nil when it has no step text."
  (when (listp entry)
    (let ((step (alist-get 'step entry)))
      (when (and (stringp step)
                 (not (string-empty-p (string-trim step))))
        (list :step (string-trim step)
              :status (codex-ide-plan--normalize-status
                       (alist-get 'status entry)))))))

(defun codex-ide-plan-normalize-update (params)
  "Return normalized structured plan update PARAMS, or nil when invalid.

The result is a plist containing `:turn-id', `:explanation', and `:steps'."
  (when (listp params)
    (let (steps)
      (dolist (entry (codex-ide-plan--sequence-list (alist-get 'plan params)))
        (when-let* ((step (codex-ide-plan--normalize-step entry)))
          (push step steps)))
      (when steps
        (let ((explanation (alist-get 'explanation params)))
          (list :turn-id (alist-get 'turnId params)
                :explanation
                (and (stringp explanation)
                     (not (string-empty-p (string-trim explanation)))
                     (string-trim explanation))
                :steps (nreverse steps)))))))

(defun codex-ide-plan-update-signature (update)
  "Return a stable duplicate-detection signature for normalized UPDATE."
  (and update
       (prin1-to-string
        (list :explanation (plist-get update :explanation)
              :steps (plist-get update :steps)))))

(defun codex-ide-plan--text (text face)
  "Return TEXT propertized with FACE for transcript rendering."
  (propertize text
              'face face
              'font-lock-face face
              'rear-nonsticky t
              'front-sticky t))

(defun codex-ide-plan--format-step (entry)
  "Return one formatted structured plan step for normalized ENTRY."
  (let ((step (plist-get entry :step)))
    (pcase (plist-get entry :status)
      ('completed
       (concat "  "
               (codex-ide-plan--text "✓ " 'success)
               (codex-ide-plan--text step 'codex-ide-plan-completed-face)
               "\n"))
      ('in-progress
       (concat "  "
               (codex-ide-plan--text "→ " 'codex-ide-plan-in-progress-face)
               (codex-ide-plan--text step 'codex-ide-plan-in-progress-face)
               "\n"))
      (_
       (concat "  "
               (codex-ide-plan--text "○ " 'shadow)
               (codex-ide-plan--text step 'codex-ide-plan-pending-face)
               "\n")))))

(defun codex-ide-plan-format-update (update)
  "Return transcript text for normalized structured plan UPDATE."
  (when update
    (concat
     (codex-ide-plan--text "* Updated plan\n" 'codex-ide-plan-heading-face)
     (when-let* ((explanation (plist-get update :explanation)))
       (concat (codex-ide-plan--text "  └ " 'shadow)
               (codex-ide-plan--text explanation
                                     'codex-ide-plan-explanation-face)
               "\n"))
     (mapconcat #'codex-ide-plan--format-step
                (plist-get update :steps)
                "")
     "\n")))

(provide 'codex-ide-plan)

;;; codex-ide-plan.el ends here
