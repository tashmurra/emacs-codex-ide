;;; codex-ide-mcp-policy-tests.el --- Tests for MCP policy catalog -*- lexical-binding: t; -*-

;;; Commentary:

;; Security and compatibility coverage for the central MCP policy gateway.

;;; Code:

(require 'ert)
(require 'json)
(require 'codex-ide-test-fixtures)
(require 'codex-ide-mcp-policy)
(require 'codex-ide-mcp-bridge)

(defun codex-ide-mcp-policy-test--catalog-with (name key value)
  "Return a catalog copy with NAME's KEY set to VALUE."
  (let* ((catalog (copy-tree codex-ide-mcp-policy--catalog))
         (entry (seq-find
                 (lambda (candidate)
                   (equal (plist-get candidate :name) name))
                 catalog)))
    (setf (plist-get entry key) value)
    catalog))

(ert-deftest codex-ide-mcp-policy-catalog-is-complete-and-unique ()
  (let ((names (codex-ide-mcp-policy-tool-names)))
    (should (= (length names) 17))
    (should (= (length names) (length (delete-dups (copy-sequence names)))))
    (should (equal (sort (copy-sequence names) #'string<)
                   (sort (copy-sequence
                          codex-ide-mcp-policy--expected-tool-names)
                         #'string<)))))

(ert-deftest codex-ide-mcp-policy-rejects-missing-fields ()
  (let ((catalog
         (codex-ide-mcp-policy-test--catalog-with
          "emacs_get_buffer_info" :handler nil)))
    (setf (car (member :handler
                       (seq-find
                        (lambda (entry)
                          (equal (plist-get entry :name)
                                 "emacs_get_buffer_info"))
                        catalog)))
          :missing-handler)
    (should-error (codex-ide-mcp-policy-validate catalog))))

(ert-deftest codex-ide-mcp-policy-rejects-invalid-combinations ()
  (should-error
   (codex-ide-mcp-policy-validate
    (codex-ide-mcp-policy-test--catalog-with
     "emacs_get_buffer_text" :approval 'auto-eligible)))
  (should-error
   (codex-ide-mcp-policy-validate
    (codex-ide-mcp-policy-test--catalog-with
     "emacs_get_messages" :access 'metadata))))

(ert-deftest codex-ide-mcp-policy-rejects-duplicate-and-unknown-tools ()
  (let ((duplicate (copy-tree codex-ide-mcp-policy--catalog))
        (unknown (copy-tree codex-ide-mcp-policy--catalog)))
    (setf (plist-get (cadr duplicate) :name)
          (plist-get (car duplicate) :name))
    (setf (plist-get (car unknown) :name) "emacs_unknown")
    (should-error (codex-ide-mcp-policy-validate duplicate))
    (should-error (codex-ide-mcp-policy-validate unknown))))

(ert-deftest codex-ide-mcp-policy-public-catalog-excludes-policy-fields ()
  (let* ((catalog-json (codex-ide-mcp-bridge--json-tool-catalog))
         (catalog (let ((json-object-type 'alist)
                        (json-array-type 'list))
                    (json-read-from-string catalog-json))))
    (should (= (length catalog) 17))
    (dolist (tool catalog)
      (should (equal (mapcar #'car tool)
                     '(name description inputSchema)))
      (should-not (string-match-p
                   "handler\\|approval\\|resource\\|result-filter\\|scope"
                   (json-encode tool))))))

(ert-deftest codex-ide-mcp-policy-catalog-generation-rejects-missing-handler ()
  (let ((codex-ide-mcp-policy--catalog
         (codex-ide-mcp-policy-test--catalog-with
          "emacs_get_buffer_info" :handler 'codex-ide-missing-handler)))
    (should-error (codex-ide-mcp-bridge--json-tool-catalog))))

(ert-deftest codex-ide-mcp-policy-approval-is-registry-allowlist-intersection ()
  (let ((codex-ide-emacs-tool-bridge-name "editor")
        (codex-ide-emacs-bridge-require-approval nil)
        (codex-ide-emacs-bridge-auto-approved-tools
         (codex-ide-mcp-policy-tool-names)))
    (should
     (codex-ide-mcp-bridge-request-exempt-from-approval-p
      '((serverName . "editor")
        (message . "run emacs_get_buffer_info"))))
    (dolist (name '("emacs_get_buffer_text"
                    "emacs_show_file_buffer"
                    "emacs_get_messages"
                    "emacs_unknown"))
      (should-not
       (codex-ide-mcp-bridge-request-exempt-from-approval-p
        `((serverName . "editor")
          (message . ,(format "run %s" name))))))))

(ert-deftest codex-ide-mcp-policy-gateway-authorizes-file-and-non-file-project-buffers ()
  (let* ((root (make-temp-file "codex-ide-policy-root-" t))
         (file (expand-file-name "inside.el" root))
         file-buffer
         non-file-buffer)
    (unwind-protect
        (progn
          (write-region "(message \"inside\")\n" nil file nil 'silent)
          (setq file-buffer (find-file-noselect file))
          (setq non-file-buffer (generate-new-buffer " *codex-policy-project*"))
          (with-current-buffer non-file-buffer
            (setq default-directory (file-name-as-directory root))
            (insert "project text"))
          (should
           (alist-get
            'buffer
            (codex-ide-mcp-bridge--tool-call
             "emacs_get_buffer_info"
             `((buffer . ,(buffer-name file-buffer)))
             (codex-ide-mcp-bridge--canonical-roots (list root)))))
          (should
           (equal
            (alist-get
             'text
             (codex-ide-mcp-bridge--tool-call
              "emacs_get_buffer_text"
              `((buffer . ,(buffer-name non-file-buffer)))
              (codex-ide-mcp-bridge--canonical-roots (list root))))
            "project text")))
      (when (buffer-live-p file-buffer) (kill-buffer file-buffer))
      (when (buffer-live-p non-file-buffer) (kill-buffer non-file-buffer))
      (delete-directory root t))))

(ert-deftest codex-ide-mcp-policy-gateway-denials-are-path-free ()
  (let* ((root (make-temp-file "codex-ide-policy-root-" t))
         (outside (make-temp-file "codex-ide-policy-secret-" nil ".el"))
         (buffer (find-file-noselect outside))
         message)
    (unwind-protect
        (condition-case err
            (codex-ide-mcp-bridge--tool-call
             "emacs_get_buffer_text"
             `((buffer . ,(buffer-name buffer)))
             (codex-ide-mcp-bridge--canonical-roots (list root)))
          (error (setq message (error-message-string err))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-file outside)
      (delete-directory root t))
    (should (string-match-p "outside allowed roots" message))
    (should-not (string-match-p "codex-ide-policy-secret" message))))

(ert-deftest codex-ide-mcp-policy-generic-content-cannot-bypass-sensitive-gate ()
  (let ((messages (get-buffer-create "*Messages*"))
        (codex-ide-mcp-bridge-allow-sensitive-state nil))
    (should-error
     (codex-ide-mcp-bridge--tool-call
      "emacs_get_buffer_text"
      `((buffer . ,(buffer-name messages)))
      (codex-ide-mcp-bridge--canonical-roots
       (list default-directory)))
     :type 'codex-ide-mcp-policy-denied)))

(ert-deftest codex-ide-mcp-policy-list-filter-removes-out-of-scope-files ()
  (let* ((root (make-temp-file "codex-ide-policy-root-" t))
         (inside (expand-file-name "inside.el" root))
         (outside (make-temp-file "codex-ide-policy-outside-" nil ".el"))
         inside-buffer
         outside-buffer)
    (unwind-protect
        (progn
          (write-region "inside" nil inside nil 'silent)
          (setq inside-buffer (find-file-noselect inside))
          (setq outside-buffer (find-file-noselect outside))
          (let* ((result
                  (codex-ide-mcp-bridge--tool-call
                   "emacs_get_all_buffers" nil
                   (codex-ide-mcp-bridge--canonical-roots (list root))))
                 (files (append (alist-get 'files result) nil)))
            (should
             (seq-some
              (lambda (item)
                (equal (alist-get 'buffer item)
                       (buffer-name inside-buffer)))
              files))
            (should-not
             (seq-some
              (lambda (item)
                (equal (alist-get 'buffer item)
                       (buffer-name outside-buffer)))
              files))))
      (when (buffer-live-p inside-buffer) (kill-buffer inside-buffer))
      (when (buffer-live-p outside-buffer) (kill-buffer outside-buffer))
      (delete-file outside)
      (delete-directory root t))))

(ert-deftest codex-ide-mcp-policy-window-filter-redacts-only-identities ()
  (let* ((root (make-temp-file "codex-ide-policy-root-" t))
         (inside (expand-file-name "inside.el" root))
         (outside (make-temp-file "codex-ide-policy-outside-" nil ".el"))
         inside-buffer
         outside-buffer)
    (unwind-protect
        (progn
          (write-region "" nil inside nil 'silent)
          (setq inside-buffer (find-file-noselect inside))
          (setq outside-buffer (find-file-noselect outside))
          (let* ((result
                  `((windows
                     . [((window-id . "inside")
                         (edges . [0 0 40 20])
                         (buffer-info
                          . ,(codex-ide-mcp-bridge--buffer-info
                              inside-buffer)))
                        ((window-id . "outside")
                         (edges . [40 0 80 20])
                         (buffer-info
                          . ,(codex-ide-mcp-bridge--buffer-info
                              outside-buffer)))])))
                 (filtered
                  (codex-ide-mcp-bridge--filter-global-windows
                   result
                   (codex-ide-mcp-bridge--canonical-roots (list root))))
                 (windows (alist-get 'windows filtered))
                 (inside-info (alist-get 'buffer-info (aref windows 0)))
                 (outside-window (aref windows 1))
                 (outside-info (alist-get 'buffer-info outside-window)))
            (should (eq (alist-get 'scoped inside-info) t))
            (should (eq (alist-get 'scoped outside-info) :json-false))
            (should (eq (alist-get 'buffer outside-info) :json-null))
            (should (eq (alist-get 'file outside-info) :json-null))
            (should (equal (alist-get 'edges outside-window)
                           [40 0 80 20]))))
      (when (buffer-live-p inside-buffer) (kill-buffer inside-buffer))
      (when (buffer-live-p outside-buffer) (kill-buffer outside-buffer))
      (delete-file outside)
      (delete-directory root t))))

(ert-deftest codex-ide-mcp-policy-active-minibuffer-is-sensitive ()
  (let ((buffer (generate-new-buffer " *codex-policy-minibuffer*"))
        (window (selected-window)))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer window buffer)
          (cl-letf (((symbol-function 'active-minibuffer-window)
                     (lambda () window)))
            (should (codex-ide-mcp-bridge--sensitive-buffer-p buffer))
            (should-error
             (codex-ide-mcp-bridge--tool-call
              "emacs_get_buffer_text"
              `((buffer . ,(buffer-name buffer)))
              (codex-ide-mcp-bridge--canonical-roots
               (list default-directory)))
             :type 'codex-ide-mcp-policy-denied)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest codex-ide-mcp-policy-project-access-fails-without-roots ()
  (let ((buffer (generate-new-buffer " *codex-policy-no-root*")))
    (unwind-protect
        (should-error
         (codex-ide-mcp-bridge--tool-call
          "emacs_get_buffer_info"
          `((buffer . ,(buffer-name buffer)))
          nil)
         :type 'codex-ide-mcp-policy-denied)
      (kill-buffer buffer))))

(ert-deftest codex-ide-mcp-policy-obsolete-root-toggle-cannot-disable-roots ()
  (let* ((root (make-temp-file "codex-ide-policy-root-" t))
         (outside (make-temp-file "codex-ide-policy-outside-" nil ".el"))
         (codex-ide-mcp-bridge-enforce-file-roots nil)
         (codex-ide-mcp-bridge-allowed-roots (list root)))
    (unwind-protect
        (should-error
         (codex-ide-mcp-bridge--safe-local-file-path outside))
      (delete-file outside)
      (delete-directory root t))))

(ert-deftest codex-ide-mcp-policy-symbol-path-filter-adds-scope-markers ()
  (let* ((root (make-temp-file "codex-ide-policy-root-" t))
         (inside (expand-file-name "inside.el" root))
         (outside (make-temp-file "codex-ide-policy-outside-" nil ".el"))
         (result `((function-file . ,inside)
                   (variable-file . ,outside))))
    (unwind-protect
        (progn
          (write-region "" nil inside nil 'silent)
          (setq result
                (codex-ide-mcp-bridge--filter-symbol-paths
                 result
                 (codex-ide-mcp-bridge--canonical-roots (list root))))
          (should (equal (alist-get 'function-file result) inside))
          (should (eq (alist-get 'function-file-scoped result) t))
          (should (eq (alist-get 'variable-file result) :json-null))
          (should (eq (alist-get 'variable-file-scoped result)
                      :json-false)))
      (delete-file outside)
      (delete-directory root t))))

(ert-deftest codex-ide-mcp-policy-decision-events-are-redacted ()
  (let (events)
    (let ((codex-ide-mcp-bridge--decision-observer
           (lambda (event) (push event events))))
      (should-error
       (codex-ide-mcp-bridge--tool-call
        "emacs_get_buffer_info"
        '((buffer . "secret-path-name"))
        nil)))
    (should (= (length events) 1))
    (should (equal (cl-loop for (key _value) on (car events) by #'cddr
                            collect key)
                   '(:tool :policy :decision :reason)))
    (should-not (string-match-p "secret-path-name"
                                (prin1-to-string events)))))

(ert-deftest codex-ide-mcp-policy-opt-in-log-is-redacted ()
  (let ((codex-ide-mcp-bridge-log-policy-decisions t)
        messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (should-error
       (codex-ide-mcp-bridge--tool-call
        "emacs_get_buffer_info"
        '((buffer . "private-buffer-name"))
        nil)))
    (should (= (length messages) 1))
    (should (string-match-p "outcome=deny" (car messages)))
    (should-not (string-match-p "private-buffer-name" (car messages)))))

(ert-deftest codex-ide-mcp-policy-gateway-and-legacy-match-in-scope-metadata ()
  (let* ((root (make-temp-file "codex-ide-policy-root-" t))
         (file (expand-file-name "inside.el" root))
         buffer)
    (unwind-protect
        (progn
          (write-region "" nil file nil 'silent)
          (setq buffer (find-file-noselect file))
          (let* ((codex-ide-mcp-bridge-allowed-roots (list root))
                 (params `((buffer . ,(buffer-name buffer))))
                 (roots (codex-ide-mcp-bridge--canonical-roots (list root)))
                 (codex-ide-mcp-bridge--dispatch-mode 'legacy)
                 (legacy (codex-ide-mcp-bridge--tool-call
                          "emacs_get_buffer_info" params roots))
                 (codex-ide-mcp-bridge--dispatch-mode 'gateway)
                 (gateway (codex-ide-mcp-bridge--tool-call
                           "emacs_get_buffer_info" params roots)))
            (should (equal legacy gateway))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(provide 'codex-ide-mcp-policy-tests)

;;; codex-ide-mcp-policy-tests.el ends here
