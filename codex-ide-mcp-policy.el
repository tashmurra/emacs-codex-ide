;;; codex-ide-mcp-policy.el --- MCP bridge tool policy catalog -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; This module owns the complete catalog for tools exposed by the optional
;; Emacs MCP bridge.  Public MCP schemas and internal authorization policy live
;; together so a tool cannot be listed without a complete policy declaration.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst codex-ide-mcp-policy--required-keys
  '(:name :description :input-schema :handler :approval :scope :access
    :resource :limit :result-filter)
  "Keys required in every MCP bridge tool policy.")

(defconst codex-ide-mcp-policy--approval-values
  '(auto-eligible required)
  "Allowed MCP bridge approval classes.")

(defconst codex-ide-mcp-policy--scope-values
  '(project-metadata global-metadata project-content project-action
    sensitive-state)
  "Allowed MCP bridge scope classes.")

(defconst codex-ide-mcp-policy--access-values
  '(metadata content display destructive check)
  "Allowed MCP bridge access classes.")

(defconst codex-ide-mcp-policy--resource-values
  '(all-file-buffers buffer buffer-or-selected selected-buffer buffers symbol
    windows path path-may-missing messages minibuffer)
  "Allowed MCP bridge resource resolver classes.")

(defconst codex-ide-mcp-policy--limit-values
  '(none buffer-text buffer-slice search-results messages)
  "Allowed MCP bridge result limit classes.")

(defconst codex-ide-mcp-policy--result-filter-values
  '(identity project-files redact-global-buffers redact-symbol-paths)
  "Allowed MCP bridge result filter classes.")

(defconst codex-ide-mcp-policy--expected-tool-names
  '("emacs_get_all_buffers"
    "emacs_get_buffer_info"
    "emacs_get_buffer_text"
    "emacs_get_buffer_diagnostics"
    "emacs_get_current_context"
    "emacs_get_buffer_slice"
    "emacs_get_region_text"
    "emacs_search_buffers"
    "emacs_get_symbol_at_point"
    "emacs_describe_symbol"
    "emacs_get_messages"
    "emacs_get_minibuffer_state"
    "emacs_get_all_windows"
    "emacs_ensure_file_buffer_open"
    "emacs_show_file_buffer"
    "emacs_kill_file_buffer"
    "emacs_lisp_check_parens")
  "Complete set of tools supported by the MCP bridge compatibility contract.")

(defconst codex-ide-mcp-policy--catalog
  (list
   (list
    :name "emacs_get_all_buffers"
    :description
    "Retrieve information all on buffers within the running Emacs instance."
    :input-schema
    `((type . "object")
      (properties . ,(make-hash-table :test 'equal))
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--get_all_buffers
    :approval 'auto-eligible
    :scope 'project-metadata
    :access 'metadata
    :resource 'all-file-buffers
    :limit 'none
    :result-filter 'project-files)
   (list
    :name "emacs_get_buffer_info"
    :description
    "Retrieve metadata -- major-mode, filename, read-only, etc -- about an open Emacs buffer is needed."
    :input-schema
    '((type . "object")
      (properties . ((buffer . ((type . "string")))))
      (required . ["buffer"])
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--get_buffer_info
    :approval 'auto-eligible
    :scope 'project-metadata
    :access 'metadata
    :resource 'buffer
    :limit 'none
    :result-filter 'identity)
   (list
    :name "emacs_get_buffer_text"
    :description
    (concat
     "Retrieve the full contents of a named Emacs buffer as a string. "
     "For use when you need to view an Emacs buffer specifically, not as a "
     "general purpose file-text reader.")
    :input-schema
    '((type . "object")
      (properties . ((buffer . ((type . "string")))))
      (required . ["buffer"])
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--get_buffer_text
    :approval 'required
    :scope 'project-content
    :access 'content
    :resource 'buffer
    :limit 'buffer-text
    :result-filter 'identity)
   (list
    :name "emacs_get_buffer_diagnostics"
    :description
    "Retrieve Flymake or Flycheck diagnostics for an Emacs buffer."
    :input-schema
    '((type . "object")
      (properties . ((buffer . ((type . "string")))))
      (required . ["buffer"])
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--get_buffer_diagnostics
    :approval 'auto-eligible
    :scope 'project-metadata
    :access 'metadata
    :resource 'buffer
    :limit 'none
    :result-filter 'identity)
   (list
    :name "emacs_get_current_context"
    :description
    "Retrieve selected window, selected buffer, point, region, visible range, and project context."
    :input-schema
    `((type . "object")
      (properties . ,(make-hash-table :test 'equal))
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--get_current_context
    :approval 'required
    :scope 'project-content
    :access 'content
    :resource 'selected-buffer
    :limit 'buffer-text
    :result-filter 'identity)
   (list
    :name "emacs_get_buffer_slice"
    :description
    "Retrieve a bounded text slice from a named buffer by line range or around point."
    :input-schema
    '((type . "object")
      (properties
       . ((buffer . ((type . "string")))
          (start-line . ((type . "integer") (minimum . 1)))
          (end-line . ((type . "integer") (minimum . 1)))
          (around-point . ((type . "integer") (minimum . 0)))))
      (required . ["buffer"])
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--get_buffer_slice
    :approval 'required
    :scope 'project-content
    :access 'content
    :resource 'buffer
    :limit 'buffer-slice
    :result-filter 'identity)
   (list
    :name "emacs_get_region_text"
    :description
    "Retrieve the active region text and bounds from a buffer, defaulting to the selected buffer."
    :input-schema
    '((type . "object")
      (properties . ((buffer . ((type . "string")))))
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--get_region_text
    :approval 'required
    :scope 'project-content
    :access 'content
    :resource 'buffer-or-selected
    :limit 'buffer-text
    :result-filter 'identity)
   (list
    :name "emacs_search_buffers"
    :description
    "Search open buffers for a string or regexp and return bounded line-oriented matches."
    :input-schema
    '((type . "object")
      (properties
       . ((pattern . ((type . "string")))
          (buffers . ((type . "array")
                      (items . ((type . "string")))
                      (minItems . 1)))
          (regexp . ((type . "boolean")))
          (max-results . ((type . "integer") (minimum . 1)))))
      (required . ["pattern" "buffers"])
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--search_buffers
    :approval 'required
    :scope 'project-content
    :access 'content
    :resource 'buffers
    :limit 'search-results
    :result-filter 'identity)
   (list
    :name "emacs_get_symbol_at_point"
    :description
    "Retrieve the symbol at point and its bounds from a buffer, defaulting to the selected buffer."
    :input-schema
    '((type . "object")
      (properties . ((buffer . ((type . "string")))))
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--get_symbol_at_point
    :approval 'auto-eligible
    :scope 'project-metadata
    :access 'metadata
    :resource 'buffer-or-selected
    :limit 'none
    :result-filter 'identity)
   (list
    :name "emacs_describe_symbol"
    :description
    "Describe an Emacs Lisp symbol, including docstrings and defining files when known."
    :input-schema
    '((type . "object")
      (properties
       . ((symbol . ((type . "string")))
          (type . ((type . "string")
                   (enum . ["any" "function" "variable" "face"])))))
      (required . ["symbol"])
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--describe_symbol
    :approval 'auto-eligible
    :scope 'global-metadata
    :access 'metadata
    :resource 'symbol
    :limit 'none
    :result-filter 'redact-symbol-paths)
   (list
    :name "emacs_get_messages"
    :description
    "Retrieve recent text from the Emacs *Messages* buffer."
    :input-schema
    '((type . "object")
      (properties . ((max-lines . ((type . "integer") (minimum . 1)))))
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--get_messages
    :approval 'required
    :scope 'sensitive-state
    :access 'content
    :resource 'messages
    :limit 'messages
    :result-filter 'identity)
   (list
    :name "emacs_get_minibuffer_state"
    :description
    "Retrieve whether the minibuffer is active and basic prompt/input state."
    :input-schema
    `((type . "object")
      (properties . ,(make-hash-table :test 'equal))
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--get_minibuffer_state
    :approval 'required
    :scope 'sensitive-state
    :access 'content
    :resource 'minibuffer
    :limit 'buffer-text
    :result-filter 'identity)
   (list
    :name "emacs_get_all_windows"
    :description
    "Retrieve all visible windows in the selected frame and their buffers."
    :input-schema
    `((type . "object")
      (properties . ,(make-hash-table :test 'equal))
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--get_all_windows
    :approval 'auto-eligible
    :scope 'global-metadata
    :access 'metadata
    :resource 'windows
    :limit 'none
    :result-filter 'redact-global-buffers)
   (list
    :name "emacs_ensure_file_buffer_open"
    :description
    "Ensure a file-backed buffer exists without displaying it in a window."
    :input-schema
    '((type . "object")
      (properties . ((path . ((type . "string")))))
      (required . ["path"])
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--ensure_file_buffer_open
    :approval 'required
    :scope 'project-action
    :access 'display
    :resource 'path
    :limit 'none
    :result-filter 'identity)
   (list
    :name "emacs_show_file_buffer"
    :description
    "Show a file-backed buffer in a non-selected Emacs window and optionally jump to line and column."
    :input-schema
    '((type . "object")
      (properties
       . ((path . ((type . "string")))
          (line . ((type . "integer") (minimum . 1)))
          (column . ((type . "integer") (minimum . 1)))))
      (required . ["path"])
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--show_file_buffer
    :approval 'required
    :scope 'project-action
    :access 'display
    :resource 'path
    :limit 'none
    :result-filter 'identity)
   (list
    :name "emacs_kill_file_buffer"
    :description
    "Kill the buffer visiting a file, prompting if it has unsaved changes."
    :input-schema
    '((type . "object")
      (properties . ((path . ((type . "string")))))
      (required . ["path"])
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--kill_file_buffer
    :approval 'required
    :scope 'project-action
    :access 'destructive
    :resource 'path-may-missing
    :limit 'none
    :result-filter 'identity)
   (list
    :name "emacs_lisp_check_parens"
    :description
    "Check a Lisp source file for mismatched parentheses and report the mismatch location when found."
    :input-schema
    '((type . "object")
      (properties . ((path . ((type . "string")))))
      (required . ["path"])
      (additionalProperties . :json-false))
    :handler 'codex-ide-mcp-bridge--tool-call--lisp_check_parens
    :approval 'required
    :scope 'project-action
    :access 'check
    :resource 'path
    :limit 'none
    :result-filter 'identity))
  "Complete tool and policy catalog for the Emacs MCP bridge.")

(defun codex-ide-mcp-policy--schema-valid-p (schema)
  "Return non-nil when SCHEMA has the required public schema shape."
  (and (listp schema)
       (equal (alist-get 'type schema) "object")
       (or (listp (alist-get 'properties schema))
           (hash-table-p (alist-get 'properties schema)))
       (eq (alist-get 'additionalProperties schema) :json-false)))

(defun codex-ide-mcp-policy--entry-error (name format-string &rest args)
  "Signal a policy error for NAME using FORMAT-STRING and ARGS."
  (error "Invalid MCP bridge policy %s: %s"
         (or name "<unnamed>")
         (apply #'format format-string args)))

(defun codex-ide-mcp-policy--validate-entry (entry)
  "Validate one policy ENTRY and return ENTRY."
  (let ((name (plist-get entry :name)))
    (dolist (key codex-ide-mcp-policy--required-keys)
      (unless (plist-member entry key)
        (codex-ide-mcp-policy--entry-error name "missing %s" key)))
    (unless (and (stringp name) (not (string-empty-p name)))
      (codex-ide-mcp-policy--entry-error name "name must be a non-empty string"))
    (unless (and (stringp (plist-get entry :description))
                 (not (string-empty-p (plist-get entry :description))))
      (codex-ide-mcp-policy--entry-error name
                                         "description must be a non-empty string"))
    (unless (codex-ide-mcp-policy--schema-valid-p
             (plist-get entry :input-schema))
      (codex-ide-mcp-policy--entry-error name "invalid public input schema"))
    (unless (symbolp (plist-get entry :handler))
      (codex-ide-mcp-policy--entry-error name "handler must be a symbol"))
    (dolist (spec `((:approval ,codex-ide-mcp-policy--approval-values)
                    (:scope ,codex-ide-mcp-policy--scope-values)
                    (:access ,codex-ide-mcp-policy--access-values)
                    (:resource ,codex-ide-mcp-policy--resource-values)
                    (:limit ,codex-ide-mcp-policy--limit-values)
                    (:result-filter
                     ,codex-ide-mcp-policy--result-filter-values)))
      (unless (memq (plist-get entry (car spec)) (cadr spec))
        (codex-ide-mcp-policy--entry-error
         name "invalid %s value %S" (car spec) (plist-get entry (car spec)))))
    (when (and (eq (plist-get entry :approval) 'auto-eligible)
               (not (eq (plist-get entry :access) 'metadata)))
      (codex-ide-mcp-policy--entry-error
       name "only metadata tools may be auto-eligible"))
    (when (and (eq (plist-get entry :scope) 'sensitive-state)
               (not (eq (plist-get entry :approval) 'required)))
      (codex-ide-mcp-policy--entry-error
       name "sensitive-state tools must require approval"))
    (pcase (plist-get entry :scope)
      ((or 'project-metadata 'global-metadata)
       (unless (eq (plist-get entry :access) 'metadata)
         (codex-ide-mcp-policy--entry-error
          name "metadata scope requires metadata access")))
      ('project-content
       (unless (and (eq (plist-get entry :access) 'content)
                    (eq (plist-get entry :approval) 'required))
         (codex-ide-mcp-policy--entry-error
          name "project content requires content access and approval")))
      ('project-action
       (unless (eq (plist-get entry :approval) 'required)
         (codex-ide-mcp-policy--entry-error
          name "project actions require approval")))
      ('sensitive-state
       (unless (eq (plist-get entry :access) 'content)
         (codex-ide-mcp-policy--entry-error
          name "sensitive state requires content access"))))
    entry))

(defun codex-ide-mcp-policy-validate (&optional catalog)
  "Validate CATALOG, or the canonical catalog, and return it.

Validation rejects duplicate names and incomplete or contradictory entries."
  (let ((catalog (or catalog codex-ide-mcp-policy--catalog))
        (seen (make-hash-table :test 'equal)))
    (unless (and (listp catalog) catalog)
      (error "Invalid MCP bridge policy catalog: expected non-empty list"))
    (dolist (entry catalog)
      (codex-ide-mcp-policy--validate-entry entry)
      (let ((name (plist-get entry :name)))
        (when (gethash name seen)
          (codex-ide-mcp-policy--entry-error name "duplicate tool name"))
        (puthash name t seen)))
    (let ((actual (sort (hash-table-keys seen) #'string<))
          (expected (sort (copy-sequence
                           codex-ide-mcp-policy--expected-tool-names)
                          #'string<)))
      (unless (equal actual expected)
        (error "Invalid MCP bridge policy catalog: tool set is incomplete or unknown")))
    catalog))

(defun codex-ide-mcp-policy-lookup (name)
  "Return the validated policy entry named NAME, or nil."
  (when (stringp name)
    (seq-find (lambda (entry)
                (equal (plist-get entry :name) name))
              (codex-ide-mcp-policy-validate))))

(defun codex-ide-mcp-policy-tool-names ()
  "Return all validated tool names in catalog order."
  (mapcar (lambda (entry) (plist-get entry :name))
          (codex-ide-mcp-policy-validate)))

(defun codex-ide-mcp-policy-public-catalog ()
  "Return the public MCP tool catalog without internal policy fields."
  (mapcar
   (lambda (entry)
     `((name . ,(plist-get entry :name))
       (description . ,(plist-get entry :description))
       (inputSchema . ,(plist-get entry :input-schema))))
   (codex-ide-mcp-policy-validate)))

(codex-ide-mcp-policy-validate)

(provide 'codex-ide-mcp-policy)

;;; codex-ide-mcp-policy.el ends here
