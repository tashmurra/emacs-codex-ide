;;; codex-ide-session-mode-tests.el --- Tests for codex-ide session mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for `codex-ide-session-mode'.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'codex-ide)
(require 'codex-ide-session-mode)

(defun codex-ide-session-mode-test--flatten-imenu-labels (index)
  "Return INDEX labels in depth-first order for assertions."
  (let (labels)
    (cl-labels ((walk (entry)
                  (push (car entry) labels)
                  (unless (markerp (cdr entry))
                    (mapc #'walk (cdr entry)))))
      (mapc #'walk index))
    (nreverse labels)))

(defun codex-ide-session-mode-test--store-mention-skills (session)
  "Store a single mention completion skill for SESSION."
  (codex-ide--session-metadata-put
   session
   :skills-list
   '(((name . "imagegen")
      (description . "Generate images.")
      (enabled . t)
      (path . "/tmp/imagegen/SKILL.md")
      (scope . "user"))))
  (codex-ide--session-metadata-put session :skills-list-state 'ready))

(ert-deftest codex-ide-session-mode-docstring-lists-key-bindings ()
  (let ((doc (documentation #'codex-ide-session-mode t)))
    (dolist (binding '("* \\<codex-ide-session-mode-map>\\[codex-ide-submit]"
                       "* \\[codex-ide-interrupt]"
                       "* \\[codex-ide-session-diff-open]"
                       "* \\[codex-ide-apply-config-preset]"
                       "* \\[codex-ide-previous-prompt-line]"
                       "* \\[codex-ide-session-mode-nav-forward]"
                       "* \\<codex-ide-session-prompt-minor-mode-map>\\[codex-ide-previous-prompt-history]"
                       "* \\<codex-ide-session-slash-command-minor-mode-map>\\[codex-ide-slash-command-complete-or-submit]"
                       "* \\<codex-ide-session-mention-minor-mode-map>\\[codex-ide-mention-complete-or-newline]"))
      (should (string-match-p (regexp-quote binding) doc)))))

(ert-deftest codex-ide-session-mode-binds-session-diff-open ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (should (eq (key-binding (kbd "C-c C-d"))
                #'codex-ide-session-diff-open))))

(ert-deftest codex-ide-session-mode-binds-apply-config-preset ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (should (eq (key-binding (kbd "C-c C-p"))
                #'codex-ide-apply-config-preset))))

(ert-deftest codex-ide-session-mode-installs-slash-command-auto-completion ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (should (memq #'codex-ide-session-mode--maybe-complete-slash-command
                  post-self-insert-hook))
    (should (memq #'codex-ide-session-mode-sync-slash-command-minor-mode
                  post-command-hook))))

(ert-deftest codex-ide-session-mode-installs-mention-auto-completion ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (should (memq #'codex-ide-session-mode--maybe-complete-mention
                  post-self-insert-hook))
    (should (memq #'codex-ide-session-mode-sync-mention-minor-mode
                  post-command-hook))))

(ert-deftest codex-ide-session-mode-slash-command-mode-binds-ret-to-complete-or-submit ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (codex-ide-session-slash-command-minor-mode 1)
    (should (eq (key-binding (kbd "RET"))
                #'codex-ide-slash-command-complete-or-submit))))

(ert-deftest codex-ide-session-mode-mention-mode-binds-ret-to-complete-or-newline ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (codex-ide-session-mention-minor-mode 1)
    (should (eq (key-binding (kbd "RET"))
                #'codex-ide-mention-complete-or-newline))))

(ert-deftest codex-ide-session-mode-enables-slash-command-mode-for-leading-slash ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((session (make-codex-ide-session
                    :buffer (current-buffer)
                    :status "idle")))
      (setq-local codex-ide--session session)
      (codex-ide--insert-input-prompt session nil)
      (goto-char (codex-ide-session-input-start-marker session))
      (insert "/")
      (codex-ide--sync-prompt-minor-mode session)
      (codex-ide-session-mode-sync-slash-command-minor-mode session)
      (should codex-ide-session-slash-command-minor-mode))))

(ert-deftest codex-ide-session-mode-disables-slash-command-mode-without-leading-slash ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((session (make-codex-ide-session
                    :buffer (current-buffer)
                    :status "idle")))
      (setq-local codex-ide--session session)
      (codex-ide--insert-input-prompt session nil)
      (goto-char (codex-ide-session-input-start-marker session))
      (insert "/")
      (codex-ide--sync-prompt-minor-mode session)
      (codex-ide-session-mode-sync-slash-command-minor-mode session)
      (should codex-ide-session-slash-command-minor-mode)
      (let ((inhibit-read-only t))
        (delete-region (codex-ide-session-input-start-marker session)
                       (1+ (marker-position
                            (codex-ide-session-input-start-marker session))))
        (insert "hello"))
      (codex-ide-session-mode-sync-slash-command-minor-mode session)
      (should-not codex-ide-session-slash-command-minor-mode))))

(ert-deftest codex-ide-session-mode-enables-mention-mode-for-leading-dollar ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
          (session (make-codex-ide-session
                    :buffer (current-buffer)
                    :status "idle")))
      (setq-local codex-ide--session session)
      (codex-ide-session-mode-test--store-mention-skills session)
      (codex-ide--insert-input-prompt session nil)
      (goto-char (codex-ide-session-input-start-marker session))
      (insert "$")
      (codex-ide--sync-prompt-minor-mode session)
      (codex-ide-session-mode-sync-mention-minor-mode session)
      (should codex-ide-session-mention-minor-mode))))

(ert-deftest codex-ide-session-mode-disables-mention-mode-without-leading-dollar ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
          (session (make-codex-ide-session
                    :buffer (current-buffer)
                    :status "idle")))
      (setq-local codex-ide--session session)
      (codex-ide-session-mode-test--store-mention-skills session)
      (codex-ide--insert-input-prompt session nil)
      (goto-char (codex-ide-session-input-start-marker session))
      (insert "$")
      (codex-ide--sync-prompt-minor-mode session)
      (codex-ide-session-mode-sync-mention-minor-mode session)
      (should codex-ide-session-mention-minor-mode)
      (let ((inhibit-read-only t))
        (delete-region (codex-ide-session-input-start-marker session)
                       (1+ (marker-position
                            (codex-ide-session-input-start-marker session))))
        (insert "hello"))
      (codex-ide-session-mode-sync-mention-minor-mode session)
      (should-not codex-ide-session-mention-minor-mode))))

(ert-deftest codex-ide-session-mode-auto-completes-leading-slash-command ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((session (make-codex-ide-session
                    :buffer (current-buffer)
                    :status "idle"))
          completion-at-point-called
          completion-help-called
          suppress-submit)
      (setq-local codex-ide--session session)
      (codex-ide--insert-input-prompt session nil)
      (goto-char (codex-ide-session-input-start-marker session))
      (insert "/")
      (cl-letf (((symbol-function 'completion-at-point)
                 (lambda ()
                   (setq completion-at-point-called t)))
                ((symbol-function 'completion-help-at-point)
                 (lambda ()
                   (setq completion-help-called t)
                   (setq suppress-submit
                         codex-ide-slash-command--suppress-completion-submit))))
        (let ((previous-event last-command-event))
          (unwind-protect
              (progn
                (setq last-command-event ?/)
                (codex-ide-session-mode--maybe-complete-slash-command))
            (setq last-command-event previous-event))))
      (should codex-ide-session-slash-command-minor-mode)
      (should completion-help-called)
      (should suppress-submit)
      (should-not completion-at-point-called))))

(ert-deftest codex-ide-session-mode-auto-completes-leading-slash-command-with-corfu ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((codex-ide-slash-commands
           '(("model" ignore "Set model.")))
          (session (make-codex-ide-session
                    :buffer (current-buffer)
                    :status "idle"))
          completion-help-called
          completion-in-region-called
          exact-match
          suppress-submit
          try-result
          candidates)
      (setq-local codex-ide--session session)
      (setq-local corfu-mode t)
      (codex-ide--insert-input-prompt session nil)
      (goto-char (codex-ide-session-input-start-marker session))
      (insert "/m")
      (cl-letf (((symbol-function 'completion-in-region)
                 (lambda (_beg _end table &optional pred)
                   (setq completion-in-region-called t)
                   (setq exact-match corfu-on-exact-match)
                   (setq suppress-submit
                         codex-ide-slash-command--suppress-completion-submit)
                   (setq try-result
                         (completion-try-completion "m" table pred 1))
                   (setq candidates
                         (all-completions "m" table pred))))
                ((symbol-function 'completion-help-at-point)
                 (lambda ()
                   (setq completion-help-called t))))
        (let ((previous-event last-command-event))
          (unwind-protect
              (progn
                (setq last-command-event ?m)
                (codex-ide-session-mode--maybe-complete-slash-command))
            (setq last-command-event previous-event))))
      (should codex-ide-session-slash-command-minor-mode)
      (should completion-in-region-called)
      (should suppress-submit)
      (should (eq exact-match 'show))
      (should (equal try-result '("m" . 1)))
      (should (equal candidates '("model")))
      (should-not completion-help-called))))

(ert-deftest codex-ide-session-mode-auto-completes-leading-mention ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
          (session (make-codex-ide-session
                    :buffer (current-buffer)
                    :status "idle"))
          completion-at-point-called
          completion-help-called)
      (setq-local codex-ide--session session)
      (codex-ide-session-mode-test--store-mention-skills session)
      (codex-ide--insert-input-prompt session nil)
      (goto-char (codex-ide-session-input-start-marker session))
      (insert "$")
      (cl-letf (((symbol-function 'completion-at-point)
                 (lambda ()
                   (setq completion-at-point-called t)))
                ((symbol-function 'completion-help-at-point)
                 (lambda ()
                   (setq completion-help-called t))))
        (let ((previous-event last-command-event))
          (unwind-protect
              (progn
                (setq last-command-event ?$)
                (codex-ide-session-mode--maybe-complete-mention))
            (setq last-command-event previous-event))))
      (should codex-ide-session-mention-minor-mode)
      (should completion-help-called)
      (should-not completion-at-point-called))))

(ert-deftest codex-ide-session-mode-auto-completes-leading-mention-with-corfu ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
          (session (make-codex-ide-session
                    :buffer (current-buffer)
                    :status "idle"))
          completion-help-called
          completion-in-region-called
          exact-match
          try-result
          candidates)
      (setq-local codex-ide--session session)
      (setq-local corfu-mode t)
      (codex-ide-session-mode-test--store-mention-skills session)
      (codex-ide--insert-input-prompt session nil)
      (goto-char (codex-ide-session-input-start-marker session))
      (insert "$i")
      (cl-letf (((symbol-function 'completion-in-region)
                 (lambda (_beg _end table &optional pred)
                   (setq completion-in-region-called t)
                   (setq exact-match corfu-on-exact-match)
                   (setq try-result
                         (completion-try-completion "i" table pred 1))
                   (setq candidates
                         (all-completions "i" table pred))))
                ((symbol-function 'completion-help-at-point)
                 (lambda ()
                   (setq completion-help-called t))))
        (let ((previous-event last-command-event))
          (unwind-protect
              (progn
                (setq last-command-event ?i)
                (codex-ide-session-mode--maybe-complete-mention))
            (setq last-command-event previous-event))))
      (should codex-ide-session-mention-minor-mode)
      (should completion-in-region-called)
      (should (eq exact-match 'show))
      (should (equal try-result '("i" . 1)))
      (should (equal candidates '("imagegen")))
      (should-not completion-help-called))))

(ert-deftest codex-ide-session-mode-preserve-sole-completion-prefix-lists-candidates ()
  (let* ((table (completion-table-dynamic
                 (lambda (_)
                   '("model"))))
         (wrapped
          (codex-ide-session-mode--preserve-sole-completion-prefix table)))
    (should (equal (complete-with-action nil wrapped "m" nil)
                   "m"))
    (should (equal (completion-try-completion "m" wrapped nil 1)
                   '("m" . 1)))
    (should (equal (all-completions "m" wrapped nil)
                   '("model")))
    (should (test-completion "model" wrapped nil))))

(ert-deftest codex-ide-session-mode-auto-completes-after-command-prefix-character ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((session (make-codex-ide-session
                    :buffer (current-buffer)
                    :status "idle"))
          called)
      (setq-local codex-ide--session session)
      (codex-ide--insert-input-prompt session nil)
      (goto-char (codex-ide-session-input-start-marker session))
      (insert "/m")
      (cl-letf (((symbol-function 'completion-help-at-point)
                 (lambda ()
                   (setq called t))))
        (let ((previous-event last-command-event))
          (unwind-protect
              (progn
                (setq last-command-event ?m)
                (codex-ide-session-mode--maybe-complete-slash-command))
            (setq last-command-event previous-event))))
      (should codex-ide-session-slash-command-minor-mode)
      (should called))))

(ert-deftest codex-ide-session-mode-does-not-auto-complete-nonleading-slash ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((session (make-codex-ide-session
                    :buffer (current-buffer)
                    :status "idle"))
          called)
      (setq-local codex-ide--session session)
      (codex-ide--insert-input-prompt session nil)
      (goto-char (codex-ide-session-input-start-marker session))
      (insert "hello /")
      (cl-letf (((symbol-function 'completion-at-point)
                 (lambda ()
                   (setq called t))))
        (codex-ide-session-mode--maybe-complete-slash-command))
      (should-not codex-ide-session-slash-command-minor-mode)
      (should-not called))))

(ert-deftest codex-ide-session-mode-imenu-indexes-user-prompts ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((inhibit-read-only t)
          first-pos
          second-pos
          index)
      (insert "> first prompt\nassistant reply\n> second prompt\nmore detail\n")
      (goto-char (point-min))
      (setq first-pos (+ (line-beginning-position) 2))
      (codex-ide-renderer-style-user-prompt-region
       (line-beginning-position)
       (line-end-position))
      (forward-line 2)
      (setq second-pos (+ (line-beginning-position) 2))
      (let ((start (line-beginning-position)))
        (forward-line 2)
        (codex-ide-renderer-style-user-prompt-region start (point)))
      (setq index (codex-ide-session-mode--imenu-create-index))
      (should (equal (codex-ide-session-mode-test--flatten-imenu-labels index)
                     '("first prompt" "second prompt↵more detail")))
      (should (= (marker-position (cdr (nth 0 index))) first-pos))
      (should (= (marker-position (cdr (nth 1 index))) second-pos)))))

(ert-deftest codex-ide-session-mode-imenu-uses-numbered-empty-prompt-labels ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((inhibit-read-only t)
          index)
      (insert "> \n")
      (goto-char (point-min))
      (codex-ide-renderer-style-user-prompt-region
       (line-beginning-position)
       (line-end-position))
      (setq index (codex-ide-session-mode--imenu-create-index))
      (should (equal (codex-ide-session-mode-test--flatten-imenu-labels index)
                     '("Prompt 1"))))))

(ert-deftest codex-ide-session-mode-imenu-normalizes-label-whitespace ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((inhibit-read-only t)
          index)
      (insert ">   prompt\twith\n spaced   words  \n# Heading\twith   spaces\n")
      (goto-char (point-min))
      (let ((start (line-beginning-position)))
        (forward-line 2)
        (codex-ide-renderer-style-user-prompt-region start (point)))
      (add-text-properties
       (point)
       (point-max)
       `(,codex-ide-agent-item-type-property "agentMessage"))
      (setq index (codex-ide-session-mode--imenu-create-index))
      (should (equal (codex-ide-session-mode-test--flatten-imenu-labels index)
                     '("prompt with↵spaced words"))))))

(ert-deftest codex-ide-session-mode-imenu-ignores-agent-messages ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((inhibit-read-only t)
          index)
      (insert "> do work\n# Implementation\nDetails\n## Validation\nDone\n")
      (goto-char (point-min))
      (codex-ide-renderer-style-user-prompt-region
       (line-beginning-position)
       (line-end-position))
      (forward-line 1)
      (let ((start (point)))
        (goto-char (point-max))
        (add-text-properties
         start
         (point)
         `(,codex-ide-agent-item-type-property "agentMessage")))
      (setq index (codex-ide-session-mode--imenu-create-index))
      (should (equal (codex-ide-session-mode-test--flatten-imenu-labels index)
                     '("do work"))))))

(ert-deftest codex-ide-session-mode-imenu-keeps-prompts-in-buffer-order ()
  (with-temp-buffer
    (codex-ide-session-mode)
    (let ((inhibit-read-only t)
          index)
      (insert "> first prompt\nAgent one\n> second prompt\nAgent two\n")
      (goto-char (point-min))
      (codex-ide-renderer-style-user-prompt-region
       (line-beginning-position)
       (line-end-position))
      (forward-line 1)
      (add-text-properties
       (line-beginning-position)
       (line-end-position)
       `(,codex-ide-agent-item-type-property "agentMessage"))
      (forward-line 1)
      (codex-ide-renderer-style-user-prompt-region
       (line-beginning-position)
       (line-end-position))
      (forward-line 1)
      (add-text-properties
       (line-beginning-position)
       (line-end-position)
       `(,codex-ide-agent-item-type-property "agentMessage"))
      (setq index (codex-ide-session-mode--imenu-create-index))
      (should (equal (codex-ide-session-mode-test--flatten-imenu-labels index)
                     '("first prompt" "second prompt"))))))

(ert-deftest codex-ide-session-mode-theme-refresh-subscribes-and-tears-down-hooks ()
  (let ((schedule-count 0)
        (codex-ide-session-mode--theme-refresh-buffers nil)
        (buffer (generate-new-buffer " *codex-ide-session-theme-test*")))
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'codex-ide-renderer-schedule-theme-refresh)
                     (lambda ()
                       (setq schedule-count (1+ schedule-count)))))
            (codex-ide-session-mode)
            (should (memq (current-buffer) codex-ide-session-mode--theme-refresh-buffers))
            (should (memq #'codex-ide-session-mode--handle-theme-change
                          enable-theme-functions))
            (should (memq #'codex-ide-session-mode--handle-theme-change
                          disable-theme-functions))
            (should (= schedule-count 1))
            (run-hook-with-args 'enable-theme-functions 'test-theme)
            (run-hook-with-args 'disable-theme-functions 'test-theme)
            (should (= schedule-count 3))
            (fundamental-mode)
            (should-not (memq (current-buffer) codex-ide-session-mode--theme-refresh-buffers))
            (should-not (memq #'codex-ide-session-mode--handle-theme-change
                              enable-theme-functions))
            (should-not (memq #'codex-ide-session-mode--handle-theme-change
                              disable-theme-functions))
            (codex-ide-session-mode)
            (should (memq (current-buffer) codex-ide-session-mode--theme-refresh-buffers))
            (should (memq #'codex-ide-session-mode--handle-theme-change
                          enable-theme-functions))
            (should (memq #'codex-ide-session-mode--handle-theme-change
                          disable-theme-functions))
            (should (= schedule-count 4))
            (run-hook-with-args 'enable-theme-functions 'test-theme)
            (should (= schedule-count 5))
            (kill-buffer buffer)
            (should-not (memq buffer codex-ide-session-mode--theme-refresh-buffers))
            (should-not (memq #'codex-ide-session-mode--handle-theme-change
                              enable-theme-functions))
            (should-not (memq #'codex-ide-session-mode--handle-theme-change
                              disable-theme-functions))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-ide-session-mode-notifies-session-diff-of-point-turn ()
  (let* ((buffer (generate-new-buffer " *codex-ide-session-diff-point-test*"))
         (session (make-instance 'codex-ide-session :buffer buffer))
         notified)
    (unwind-protect
        (with-current-buffer buffer
          (codex-ide-session-mode)
          (setq-local codex-ide--session session)
          (let ((inhibit-read-only t))
            (insert "> first\nresult\n\n> second\nresult\n"))
          (goto-char (point-min))
          (let ((first-marker (copy-marker (point) nil)))
            (search-forward "> second")
            (let ((second-marker (copy-marker (match-beginning 0) nil)))
              (codex-ide--record-turn-start session "turn-1" first-marker)
              (codex-ide--record-turn-start session "turn-2" second-marker)
              (cl-letf (((symbol-function
                          'codex-ide-session-diff-transcript-point-changed)
                         (lambda (notified-session turn-id)
                           (setq notified
                                 (list notified-session turn-id)))))
                (codex-ide-session-mode--notify-diff-point-changed)
                (should (equal notified (list session "turn-2")))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'codex-ide-session-mode-tests)

;;; codex-ide-session-mode-tests.el ends here
