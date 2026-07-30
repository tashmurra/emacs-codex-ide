;;; codex-ide-mcp-bridge.el --- Emacs MCP bridge helpers for codex-ide -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; This module provides the Emacs-side half of the optional Codex MCP bridge.
;; The external MCP server talks to the running Emacs instance via emacsclient
;; and dispatches JSON tool calls into `codex-ide-mcp-bridge--tool-call'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'server)
(require 'subr-x)
(require 'thingatpt)
(require 'codex-ide-mcp-policy)

(defconst codex-ide-mcp-bridge--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the codex-ide bridge files.")

;;;###autoload
(defcustom codex-ide-enable-emacs-tool-bridge nil
  "Whether codex-ide should expose Emacs tools to Codex via MCP.

When non-nil, codex-ide starts an MCP bridge server alongside `codex app-server'
and ensures the current Emacs instance is reachable via `emacsclient'."
  :type 'boolean
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-want-mcp-bridge 'prompt
  "Whether codex-ide should start the Emacs MCP bridge.

When nil, do not start the bridge.  When t, start the bridge without prompting.
When `prompt', ask before enabling the bridge, matching the historical startup
behavior."
  :type '(choice (const :tag "Do not start" nil)
                 (const :tag "Start without prompting" t)
                 (const :tag "Prompt at startup" prompt))
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-emacs-tool-bridge-name "codex-ide-emacs-mcp"
  "Name used when registering the Emacs MCP bridge with Codex."
  :type 'string
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-emacs-bridge-python-command "python3"
  "Python executable used to launch the standalone Emacs MCP bridge."
  :type 'string
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-emacs-bridge-emacsclient-command "emacsclient"
  "Path to the `emacsclient' executable used by the bridge."
  :type 'string
  :group 'codex-ide)

(defcustom codex-ide-mcp-bridge-search-result-text-limit 500
  "Maximum number of characters returned for each search result line."
  :type 'integer
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-mcp-bridge-buffer-slice-text-limit 50000
  "Maximum number of characters returned by one buffer slice request."
  :type 'integer
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-mcp-bridge-enforce-file-roots t
  "Obsolete compatibility setting; bridge file roots are always enforced.

Setting this to nil no longer disables file-root enforcement."
  :type 'boolean
  :group 'codex-ide)

(make-obsolete-variable 'codex-ide-mcp-bridge-enforce-file-roots nil "0.3.3")

;;;###autoload
(defcustom codex-ide-mcp-bridge-allowed-roots nil
  "Additional local roots bridge file tools may access.

Session startup automatically passes the session working directory as an
allowed root.  This option is for explicit extra roots."
  :type '(repeat directory)
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-mcp-bridge-buffer-text-limit
  codex-ide-mcp-bridge-buffer-slice-text-limit
  "Maximum number of characters returned by a full buffer text request."
  :type 'integer
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-mcp-bridge-allow-sensitive-state nil
  "Whether bridge tools may expose Messages and active minibuffer contents."
  :type 'boolean
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-mcp-bridge-log-policy-decisions nil
  "Whether to log redacted MCP bridge policy decisions.

Events contain only the tool name, fixed policy class, allow or deny outcome,
and a reason code.  Tool arguments, paths, buffer text, and results are never
included."
  :type 'boolean
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-emacs-bridge-script-path nil
  "Path to the standalone Emacs MCP bridge script.

When nil, codex-ide uses `bin/codex-ide-mcp-server.py' from the package directory."
  :type '(choice (const :tag "Default" nil)
                 (file :tag "Bridge script"))
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-emacs-bridge-server-name nil
  "Server name the bridge should use with `emacsclient'.

When nil, use the current value of `server-name'."
  :type '(choice (const :tag "Current server" nil)
                 (string :tag "Named server"))
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-suppress-server-start-prompts nil
  "When non-nil, start the Emacs server for the bridge without prompting.

This only affects explicit calls to `codex-ide-mcp-bridge-ensure-server'.  Session
startup now prompts once about enabling the Emacs tool bridge, and enabling the
bridge starts the Emacs server automatically when needed."
  :type 'boolean
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-emacs-bridge-startup-timeout 10
  "Startup timeout in seconds for the Emacs MCP bridge."
  :type 'integer
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-emacs-bridge-tool-timeout 60
  "Tool-call timeout in seconds for the Emacs MCP bridge."
  :type 'integer
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-emacs-bridge-require-approval t
  "Whether Emacs MCP bridge tool calls should require user approval.

When nil, `codex-ide' auto-accepts approval-like MCP elicitations that clearly
refer to the configured Emacs MCP bridge server or one of its tools."
  :type 'boolean
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-emacs-bridge-auto-approved-tools
  '("emacs_get_all_buffers"
    "emacs_get_buffer_info"
    "emacs_get_buffer_diagnostics"
    "emacs_get_symbol_at_point"
    "emacs_describe_symbol"
    "emacs_get_all_windows")
  "Bridge tools requested for auto-exemption when approvals are disabled.

This list can narrow the fixed policy catalog, but it cannot make a tool
auto-eligible when its catalog policy requires approval."
  :type '(repeat string)
  :group 'codex-ide)

(defconst codex-ide-mcp-bridge--approval-sensitive-tool-names
  (seq-keep
   (lambda (name)
     (when (eq (plist-get (codex-ide-mcp-policy-lookup name) :approval)
               'required)
       name))
   (codex-ide-mcp-policy-tool-names))
  "Compatibility view of tools whose registry policy requires approval.")

(defvar codex-ide-mcp-bridge--request-allowed-roots nil
  "Allowed roots supplied by the current MCP tool-call metadata.")

(cl-defstruct (codex-ide-mcp-bridge-request-context
               (:constructor codex-ide-mcp-bridge--make-request-context))
  "Short-lived authorization context for one MCP bridge request."
  name
  policy
  allowed-roots
  resources)

(defvar codex-ide-mcp-bridge--request-context nil
  "Dynamically bound authorization context for the current bridge request.")

(defvar codex-ide-mcp-bridge--decision-observer nil
  "Internal function called with redacted bridge policy decision metadata.")

(defvar codex-ide-mcp-bridge--dispatch-mode 'gateway
  "Internal dispatch mode, either `gateway' or compatibility `legacy'.")

(defvar codex-ide-mcp-bridge--root-warning-shown nil
  "Whether the obsolete file-root setting warning has been shown.")

(defun codex-ide-mcp-bridge--toml-string (value)
  "Encode VALUE as a TOML string."
  (format "\"%s\""
          (replace-regexp-in-string
           "\"" "\\\\\""
           (replace-regexp-in-string "\\\\" "\\\\\\\\"
                                     (or value "")
                                     t t)
           t t)))

(defun codex-ide-mcp-bridge--toml-array (values)
  "Encode VALUES as a TOML array."
  (format "[%s]"
          (string-join (mapcar #'codex-ide-mcp-bridge--toml-string values) ",")))

(defun codex-ide-mcp-bridge--resolved-script-path ()
  "Return the absolute path to the standalone bridge script."
  (expand-file-name
   (or codex-ide-emacs-bridge-script-path "bin/codex-ide-mcp-server.py")
   codex-ide-mcp-bridge--directory))

(defun codex-ide-mcp-bridge--resolved-server-name ()
  "Return the emacsclient server name the bridge should target."
  (or codex-ide-emacs-bridge-server-name server-name))

(defun codex-ide-mcp-bridge--approval-tool-name-from-message (message)
  "Return an Emacs bridge tool name parsed from approval MESSAGE."
  (when (stringp message)
    (cond
     ((string-match "tool[[:space:]\n]+\"\\([^\"]+\\)\"" message)
      (match-string 1 message))
     ((string-match "\\brun[[:space:]\n]+\\(emacs_[[:alnum:]_]+\\)\\b"
                    message)
      (match-string 1 message)))))

(defun codex-ide-mcp-bridge--approval-tool-name-from-value (value)
  "Return the first bridge tool name found in VALUE."
  (cond
   ((and (consp value)
         (eq (car value) 'tool)
         (stringp (cdr value)))
    (cdr value))
   ((and (consp value)
         (stringp (alist-get 'tool value)))
    (alist-get 'tool value))
   ((consp value)
    (or (codex-ide-mcp-bridge--approval-tool-name-from-value (car value))
        (codex-ide-mcp-bridge--approval-tool-name-from-value (cdr value))))
   ((vectorp value)
    (seq-some #'codex-ide-mcp-bridge--approval-tool-name-from-value
              (append value nil)))))

(defun codex-ide-mcp-bridge--approval-tool-name (params)
  "Return the bridge tool name described by approval PARAMS, if present."
  (or (codex-ide-mcp-bridge--approval-tool-name-from-value
       (alist-get 'permissions params))
      (codex-ide-mcp-bridge--approval-tool-name-from-message
       (alist-get 'message params))
      (codex-ide-mcp-bridge--approval-tool-name-from-message
       (alist-get 'reason params))))

;;;###autoload
(defun codex-ide-mcp-bridge-request-exempt-from-approval-p (params)
  "Return non-nil when PARAMS describe an Emacs MCP bridge request.

This is used to bypass bridge-originated elicitation prompts when
`codex-ide-emacs-bridge-require-approval' is nil."
  (let* ((tool-name (codex-ide-mcp-bridge--approval-tool-name params))
         (policy (codex-ide-mcp-policy-lookup tool-name)))
    (and (not codex-ide-emacs-bridge-require-approval)
         (equal (alist-get 'serverName params)
                codex-ide-emacs-tool-bridge-name)
         (member tool-name codex-ide-emacs-bridge-auto-approved-tools)
         (eq (plist-get policy :approval) 'auto-eligible))))

;;;###autoload
(defun codex-ide-mcp-bridge-enabled-p ()
  "Return non-nil when the Emacs MCP bridge should be enabled."
  (cond
   ((eq codex-ide-want-mcp-bridge nil) nil)
   ((eq codex-ide-want-mcp-bridge t) t)
   ((eq codex-ide-want-mcp-bridge 'prompt)
    codex-ide-enable-emacs-tool-bridge)
   (t nil)))

;;;###autoload
(defun codex-ide-mcp-bridge-enable ()
  "Enable the Emacs MCP bridge and ensure the target Emacs server is running."
  (setq codex-ide-enable-emacs-tool-bridge t)
  (when (eq codex-ide-want-mcp-bridge nil)
    (setq codex-ide-want-mcp-bridge t))
  (codex-ide-mcp-bridge-ensure-server))

;;;###autoload
(defun codex-ide-mcp-bridge-disable ()
  "Disable the Emacs MCP bridge."
  (setq codex-ide-want-mcp-bridge nil)
  (setq codex-ide-enable-emacs-tool-bridge nil)
  codex-ide-enable-emacs-tool-bridge)

;;;###autoload
(defun codex-ide-mcp-bridge-prompt-to-enable ()
  "Prompt once to enable the Emacs MCP bridge for session startup."
  (cond
   ((eq codex-ide-want-mcp-bridge t)
    (codex-ide-mcp-bridge-enable))
   ((eq codex-ide-want-mcp-bridge 'prompt)
    (when (and (not (codex-ide-mcp-bridge-enabled-p))
               (y-or-n-p "Enable the Emacs tool bridge for this Codex session? "))
      (codex-ide-mcp-bridge-enable)))))

(defun codex-ide-mcp-bridge--ensure-server-running-p (target-server-name)
  "Return non-nil when TARGET-SERVER-NAME is running.
Errors from `server-running-p' are treated as nil."
  (server-running-p target-server-name))

;;;###autoload
(defun codex-ide-mcp-bridge-status ()
  "Return an alist describing the current Emacs bridge configuration."
  (let* ((enabled (codex-ide-mcp-bridge-enabled-p))
         (script-path (codex-ide-mcp-bridge--resolved-script-path))
         (python-path (and enabled
                           (executable-find codex-ide-emacs-bridge-python-command)))
         (emacsclient-path (and enabled
                                (executable-find
                                 codex-ide-emacs-bridge-emacsclient-command)))
         (server-name (codex-ide-mcp-bridge--resolved-server-name))
         (server-running (and enabled
                              (codex-ide-mcp-bridge--ensure-server-running-p
                               server-name)))
         (ready (and enabled
                     (file-exists-p script-path)
                     python-path
                     emacsclient-path)))
    `((enabled . ,enabled)
      (want . ,codex-ide-want-mcp-bridge)
      (ready . ,ready)
      (scriptPath . ,script-path)
      (scriptExists . ,(file-exists-p script-path))
      (pythonCommand . ,codex-ide-emacs-bridge-python-command)
      (pythonPath . ,python-path)
      (emacsclientCommand . ,codex-ide-emacs-bridge-emacsclient-command)
      (emacsclientPath . ,emacsclient-path)
      (serverName . ,server-name)
      (serverRunning . ,server-running))))

;;;###autoload
(defun codex-ide-mcp-bridge-ensure-server ()
  "Ensure the target Emacs server for the bridge is running."
  (when (codex-ide-mcp-bridge-enabled-p)
    (let ((server-name (codex-ide-mcp-bridge--resolved-server-name)))
      (unless (codex-ide-mcp-bridge--ensure-server-running-p server-name)
        (server-start nil codex-ide-suppress-server-start-prompts)))))

(defun codex-ide-mcp-bridge--local-root-argument (root)
  "Return ROOT as a local absolute CLI argument, or nil."
  (when (and (stringp root)
             (not (string-empty-p root))
             (not (file-remote-p root)))
    (directory-file-name (expand-file-name root))))

(defun codex-ide-mcp-bridge--warn-obsolete-root-setting ()
  "Warn once when obsolete root enforcement has been set to nil."
  (when (and (not codex-ide-mcp-bridge-enforce-file-roots)
             (not codex-ide-mcp-bridge--root-warning-shown))
    (setq codex-ide-mcp-bridge--root-warning-shown t)
    (display-warning
     'codex-ide
     (concat "`codex-ide-mcp-bridge-enforce-file-roots' is obsolete; "
             "MCP bridge roots are always enforced")
     :warning)))

(defun codex-ide-mcp-bridge--mcp-config-allowed-roots (working-dir)
  "Return local roots that should be passed for WORKING-DIR."
  (seq-filter
   #'identity
   (mapcar #'codex-ide-mcp-bridge--local-root-argument
           (append (when working-dir (list working-dir))
                   codex-ide-mcp-bridge-allowed-roots))))

(defun codex-ide-mcp-bridge--allowed-root-args (roots)
  "Return bridge script arguments for allowed ROOTS."
  (apply #'append
         (mapcar (lambda (root)
                   (list "--allowed-root" root))
                 roots)))

;;;###autoload
(defun codex-ide-mcp-bridge-mcp-config-args (&optional working-dir)
  "Return `codex app-server' CLI args that register the Emacs MCP bridge.

When WORKING-DIR is non-nil, pass it to the bridge server as an allowed root."
  (when (codex-ide-mcp-bridge-enabled-p)
    (codex-ide-mcp-bridge--warn-obsolete-root-setting)
    (let* ((bridge-name codex-ide-emacs-tool-bridge-name)
           (prefix (format "mcp_servers.%s" bridge-name))
           (script-path (codex-ide-mcp-bridge--resolved-script-path))
           (python-command
            (or (executable-find codex-ide-emacs-bridge-python-command)
                codex-ide-emacs-bridge-python-command))
           (emacsclient-command
            (or (executable-find codex-ide-emacs-bridge-emacsclient-command)
                codex-ide-emacs-bridge-emacsclient-command))
           (server-name codex-ide-emacs-bridge-server-name)
           (allowed-roots
            (codex-ide-mcp-bridge--mcp-config-allowed-roots working-dir))
           (script-args
            (append (list script-path
                          "--emacsclient"
                          emacsclient-command)
                    (when (and server-name
                               (not (string-empty-p server-name)))
                      (list "--server-name" server-name))
                    (codex-ide-mcp-bridge--allowed-root-args allowed-roots))))
      (list "-c" (format "%s.command=%s"
                         prefix
                         (codex-ide-mcp-bridge--toml-string
                          python-command))
            "-c" (format "%s.args=%s"
                         prefix
                         (codex-ide-mcp-bridge--toml-array script-args))
            "-c" (format "%s.startup_timeout_sec=%s"
                         prefix
                         codex-ide-emacs-bridge-startup-timeout)
            "-c" (format "%s.tool_timeout_sec=%s"
                         prefix
                         codex-ide-emacs-bridge-tool-timeout)))))

(defun codex-ide-mcp-bridge--json-bool (value)
  "Return VALUE as an explicit JSON boolean."
  (if value t :json-false))

(defun codex-ide-mcp-bridge--json-nullable (value)
  "Return VALUE or an explicit JSON null."
  (or value :json-null))

(defun codex-ide-mcp-bridge--json-array (values)
  "Return VALUES as a JSON array."
  (vconcat values))

(defun codex-ide-mcp-bridge--buffer-info (buffer &optional redacted)
  "Return a buffer-info alist for BUFFER.

When REDACTED is non-nil, preserve non-identifying state while replacing the
buffer and file identities with JSON nulls."
  (with-current-buffer buffer
    `((buffer . ,(if redacted :json-null (buffer-name buffer)))
      (file . ,(if redacted
                   :json-null
                 (codex-ide-mcp-bridge--json-nullable
                  (when-let* ((file (buffer-file-name buffer)))
                    (expand-file-name file)))))
      (scoped . ,(codex-ide-mcp-bridge--json-bool (not redacted)))
      (major-mode . ,(symbol-name major-mode))
      (modified . ,(codex-ide-mcp-bridge--json-bool
                    (buffer-modified-p buffer)))
      (read-only . ,(codex-ide-mcp-bridge--json-bool
                     buffer-read-only)))))

(defun codex-ide-mcp-bridge--buffer-from-params (params &optional default-buffer)
  "Return buffer named by PARAMS, falling back to DEFAULT-BUFFER."
  (let* ((buffer-name (alist-get 'buffer params))
         (buffer (if (stringp buffer-name)
                     (get-buffer buffer-name)
                   (or default-buffer (current-buffer)))))
    (unless buffer
      (error "Unknown buffer: %s" (or buffer-name "nil")))
    buffer))

(defun codex-ide-mcp-bridge--canonical-root (root)
  "Return ROOT as a local existing truename directory, or nil."
  (when-let* ((local-root (codex-ide-mcp-bridge--local-root-argument root)))
    (when (file-directory-p local-root)
      (file-name-as-directory (file-truename local-root)))))

(defun codex-ide-mcp-bridge--canonical-roots (roots)
  "Return unique canonical local directories from ROOTS."
  (delete-dups (seq-keep #'codex-ide-mcp-bridge--canonical-root roots)))

(defun codex-ide-mcp-bridge--effective-allowed-root-truenames ()
  "Return local, existing allowed roots as truename directories."
  (or (and codex-ide-mcp-bridge--request-context
           (codex-ide-mcp-bridge-request-context-allowed-roots
            codex-ide-mcp-bridge--request-context))
      (codex-ide-mcp-bridge--canonical-roots
       (append codex-ide-mcp-bridge--request-allowed-roots
               codex-ide-mcp-bridge-allowed-roots))))

(defun codex-ide-mcp-bridge--path-inside-root-p (true-path true-root)
  "Return non-nil when TRUE-PATH is inside TRUE-ROOT."
  (or (string= true-path (directory-file-name true-root))
      (string-prefix-p true-root true-path)))

(defun codex-ide-mcp-bridge--file-truename (path)
  "Return truename for PATH, surfacing failures as bridge errors."
  (condition-case err
      (file-truename path)
    (error
     (error "Unable to resolve file path %S: %s"
            path
            (error-message-string err)))))

(defun codex-ide-mcp-bridge--path-in-roots-p (path roots)
  "Return non-nil when local existing PATH resolves inside ROOTS."
  (when (and (stringp path)
             (not (string-empty-p path))
             (not (file-remote-p path))
             (file-exists-p path))
    (condition-case nil
        (let ((true-path (file-truename (expand-file-name path))))
          (seq-some
           (lambda (root)
             (codex-ide-mcp-bridge--path-inside-root-p true-path root))
           roots))
      (error nil))))

(defun codex-ide-mcp-bridge--directory-in-roots-p (directory roots)
  "Return non-nil when local existing DIRECTORY resolves inside ROOTS."
  (when (and (stringp directory)
             (not (string-empty-p directory))
             (not (file-remote-p directory))
             (file-directory-p directory))
    (condition-case nil
        (let ((true-directory
               (directory-file-name
                (file-truename (expand-file-name directory)))))
          (seq-some
           (lambda (root)
             (codex-ide-mcp-bridge--path-inside-root-p true-directory root))
           roots))
      (error nil))))

(defun codex-ide-mcp-bridge--sensitive-buffer-p (buffer)
  "Return non-nil when BUFFER contains specially protected editor state."
  (or (equal (buffer-name buffer) "*Messages*")
      (let ((window (active-minibuffer-window)))
        (and window (eq buffer (window-buffer window))))))

(defun codex-ide-mcp-bridge--buffer-in-roots-p (buffer roots)
  "Return non-nil when BUFFER belongs to one of ROOTS."
  (with-current-buffer buffer
    (if-let* ((file (buffer-file-name buffer)))
        (codex-ide-mcp-bridge--path-in-roots-p file roots)
      (codex-ide-mcp-bridge--directory-in-roots-p default-directory roots))))

(defun codex-ide-mcp-bridge--assert-buffer-authorized (buffer policy)
  "Return BUFFER after applying POLICY scope and sensitivity checks."
  (let ((scope (plist-get policy :scope))
        (roots (codex-ide-mcp-bridge--effective-allowed-root-truenames)))
    (when (codex-ide-mcp-bridge--sensitive-buffer-p buffer)
      (unless (and (eq scope 'project-content)
                   codex-ide-mcp-bridge-allow-sensitive-state)
        (codex-ide-mcp-bridge--deny
         'sensitive-resource "sensitive editor state")))
    (when (memq scope '(project-metadata project-content))
      (unless (and roots
                   (codex-ide-mcp-bridge--buffer-in-roots-p buffer roots))
        (codex-ide-mcp-bridge--deny
         'outside-roots "resource outside allowed roots")))
    buffer))

(defun codex-ide-mcp-bridge--assert-buffer-for-tool (buffer name)
  "Revalidate BUFFER at its handler sink using the policy for NAME."
  (when codex-ide-mcp-bridge--request-context
    (let ((policy (codex-ide-mcp-policy-lookup name)))
      (unless policy
        (codex-ide-mcp-bridge--deny 'invalid-policy "missing tool policy"))
      (codex-ide-mcp-bridge--assert-buffer-authorized buffer policy)))
  buffer)

(defun codex-ide-mcp-bridge--safe-local-file-path (path &optional allow-missing)
  "Return absolute local PATH after validating bridge file access.

When ALLOW-MISSING is non-nil, a nonexistent path may pass root validation for
tools that only check whether a buffer is already visiting that path."
  (unless (and (stringp path) (not (string-empty-p path)))
    (error "Missing file path"))
  (when (file-remote-p path)
    (error "Remote file paths are not allowed: %s" path))
  (let ((expanded-path (expand-file-name path)))
    (when (file-remote-p expanded-path)
      (error "Remote file paths are not allowed: %s" path))
    (when (file-directory-p expanded-path)
      (error "Directories are not allowed: %s" expanded-path))
    (unless (or allow-missing (file-exists-p expanded-path))
      (error "File does not exist: %s" expanded-path))
    (when (and (file-exists-p expanded-path)
               (not (file-regular-p expanded-path)))
      (error "Path is not a regular file: %s" expanded-path))
    (let ((true-path (codex-ide-mcp-bridge--file-truename expanded-path))
          (roots (codex-ide-mcp-bridge--effective-allowed-root-truenames)))
      (unless roots
        (error "No allowed file roots configured for bridge request"))
      (unless (seq-some
               (lambda (root)
                 (codex-ide-mcp-bridge--path-inside-root-p true-path root))
               roots)
        (error "File is outside allowed roots: %s" expanded-path))
      expanded-path)))

(defun codex-ide-mcp-bridge--assert-buffer-file-readable (buffer)
  "Validate that BUFFER's file, when present, is readable by bridge policy."
  (when-let* ((file (buffer-file-name buffer)))
    (codex-ide-mcp-bridge--safe-local-file-path file))
  buffer)

(defun codex-ide-mcp-bridge--line-text-at-point ()
  "Return the current line text without text properties."
  (buffer-substring-no-properties
   (line-beginning-position)
   (line-end-position)))

(defun codex-ide-mcp-bridge--bounded-line-text-at-point (position limit)
  "Return bounded line text around POSITION with at most LIMIT characters.

The result is an alist containing `text', `text-truncated', and
`text-start-column'."
  (let* ((line-start (line-beginning-position))
         (line-end (line-end-position))
         (line-length (- line-end line-start))
         (limit (if (and (integerp limit) (> limit 0)) limit line-length))
         (truncated (> line-length limit))
         (offset (max 0 (- position line-start)))
         (start-offset (if truncated
                           (max 0
                                (min (- line-length limit)
                                     (- offset (/ limit 2))))
                         0))
         (text-start (+ line-start start-offset))
         (text-end (min line-end (+ text-start limit))))
    `((text . ,(buffer-substring-no-properties text-start text-end))
      (text-truncated . ,(codex-ide-mcp-bridge--json-bool truncated))
      (text-start-column . ,(1+ start-offset)))))

(defun codex-ide-mcp-bridge--point-location ()
  "Return an alist describing point in the current buffer."
  `((point . ,(point))
    (line . ,(line-number-at-pos))
    (column . ,(1+ (current-column)))))

(defun codex-ide-mcp-bridge--region-info ()
  "Return active region bounds and text for the current buffer."
  (if (use-region-p)
      (let ((start (region-beginning))
            (end (region-end)))
        `((active . t)
          (start . ,start)
          (end . ,end)
          (start-line . ,(line-number-at-pos start))
          (start-column . ,(save-excursion
                             (goto-char start)
                             (1+ (current-column))))
          (end-line . ,(line-number-at-pos end))
          (end-column . ,(save-excursion
                           (goto-char end)
                           (1+ (current-column))))
          (text . ,(buffer-substring-no-properties start end))))
    '((active . :json-false)
      (start . :json-null)
      (end . :json-null)
      (start-line . :json-null)
      (start-column . :json-null)
      (end-line . :json-null)
      (end-column . :json-null)
      (text . :json-null))))

(defun codex-ide-mcp-bridge--project-root ()
  "Return the current project root, or nil when unavailable."
  (when (require 'project nil t)
    (when-let* ((project (ignore-errors (project-current nil))))
      (expand-file-name (project-root project)))))

(defun codex-ide-mcp-bridge--goto-line-end-inclusive (line)
  "Move to the end of LINE, accepting LINE values past the buffer end."
  (goto-char (point-min))
  (forward-line (1- line))
  (line-end-position))

(defun codex-ide-mcp-bridge--diagnostic-severity (diagnostic)
  "Return a normalized severity string for DIAGNOSTIC."
  (cond
   ((and (fboundp 'flymake-diagnostic-type)
         (ignore-errors (flymake-diagnostic-type diagnostic)))
    (pcase (flymake-diagnostic-type diagnostic)
      ('eglot-note "note")
      ('eglot-warning "warning")
      ('eglot-error "error")
      ('warning "warning")
      ('error "error")
      (_ (format "%s" (flymake-diagnostic-type diagnostic)))))
   ((and (fboundp 'flycheck-error-level)
         (ignore-errors (flycheck-error-level diagnostic)))
    (let* ((level (flycheck-error-level diagnostic))
           (severity (and (fboundp 'flycheck-error-level-severity)
                          (flycheck-error-level-severity level)))
           (level-id (or (and (fboundp 'flycheck-error-level-id)
                              (flycheck-error-level-id level))
                         level)))
      (cond
       ((and severity (<= severity 0)) "error")
       ((and severity (= severity 1)) "warning")
       ((symbolp level-id) (symbol-name level-id))
       (level-id (format "%s" level-id))
       (t "unknown"))))
   (t "unknown")))

(defun codex-ide-mcp-bridge--flymake-diagnostics ()
  "Return current Flymake diagnostics as a list of alists."
  (when (and (boundp 'flymake-mode)
             flymake-mode
             (fboundp 'flymake-diagnostics))
    (mapcar
     (lambda (diag)
       `((source . "flymake")
         (buffer . ,(buffer-name))
         (file . ,(codex-ide-mcp-bridge--json-nullable
                   (when-let* ((file (buffer-file-name)))
                     (expand-file-name file))))
         (message . ,(flymake-diagnostic-text diag))
         (severity . ,(codex-ide-mcp-bridge--diagnostic-severity diag))
         (line . ,(line-number-at-pos (flymake-diagnostic-beg diag)))
         (column . ,(save-excursion
                      (goto-char (flymake-diagnostic-beg diag))
                      (1+ (current-column))))
         (end-line . ,(line-number-at-pos (flymake-diagnostic-end diag)))
         (end-column . ,(save-excursion
                          (goto-char (flymake-diagnostic-end diag))
                          (1+ (current-column))))))
     (flymake-diagnostics))))

(defun codex-ide-mcp-bridge--flycheck-diagnostics ()
  "Return current Flycheck diagnostics as a list of alists."
  (when (and (boundp 'flycheck-mode)
             flycheck-mode
             (boundp 'flycheck-current-errors)
             flycheck-current-errors)
    (mapcar
     (lambda (err)
       `((source . "flycheck")
         (buffer . ,(buffer-name))
         (file . ,(codex-ide-mcp-bridge--json-nullable
                   (when-let* ((file (or (and (fboundp 'flycheck-error-filename)
                                             (flycheck-error-filename err))
                                        (buffer-file-name))))
                     (expand-file-name file))))
         (message . ,(or (and (fboundp 'flycheck-error-message)
                              (flycheck-error-message err))
                         ""))
         (severity . ,(codex-ide-mcp-bridge--diagnostic-severity err))
         (line . ,(or (and (fboundp 'flycheck-error-line)
                           (flycheck-error-line err))
                      1))
         (column . ,(or (and (fboundp 'flycheck-error-column)
                             (flycheck-error-column err))
                        1))
         (end-line . ,(or (and (fboundp 'flycheck-error-end-line)
                               (flycheck-error-end-line err))
                          :json-null))
         (end-column . ,(or (and (fboundp 'flycheck-error-end-column)
                                 (flycheck-error-end-column err))
                            :json-null))))
     flycheck-current-errors)))

(define-error 'codex-ide-mcp-policy-denied "MCP bridge policy denied request")

(defun codex-ide-mcp-bridge--deny (reason message)
  "Deny a bridge request with redacted REASON and MESSAGE."
  (signal 'codex-ide-mcp-policy-denied
          (list (format "Bridge request denied: %s" message) reason)))

(defun codex-ide-mcp-bridge--emit-decision
    (name policy decision reason)
  "Emit a redacted policy event for NAME, POLICY, DECISION, and REASON."
  (when codex-ide-mcp-bridge-log-policy-decisions
    (message "codex-ide MCP policy tool=%s class=%s outcome=%s reason=%s"
             name
             (or (and policy (plist-get policy :scope)) 'unknown)
             decision
             reason))
  (when (functionp codex-ide-mcp-bridge--decision-observer)
    (funcall codex-ide-mcp-bridge--decision-observer
             (list :tool name
                   :policy (and policy (plist-get policy :scope))
                   :decision decision
                   :reason reason))))

(defun codex-ide-mcp-bridge--validate-tool-handlers ()
  "Validate that every catalog policy names an implemented handler."
  (dolist (name (codex-ide-mcp-policy-tool-names))
    (let* ((policy (codex-ide-mcp-policy-lookup name))
           (handler (plist-get policy :handler)))
      (unless (fboundp handler)
        (error "Invalid MCP bridge policy %s: handler %S is not implemented"
               name handler))))
  t)

(defun codex-ide-mcp-bridge--request-roots (meta)
  "Return validated raw request roots from META."
  (unless (or (null meta) (listp meta))
    (codex-ide-mcp-bridge--deny 'invalid-context
                                "invalid request context"))
  (let ((roots (and meta (alist-get 'allowedRoots meta))))
    (unless (or (null roots) (listp roots))
      (codex-ide-mcp-bridge--deny 'invalid-context
                                  "invalid allowed-root context"))
    (dolist (root roots)
      (unless (and (stringp root)
                   (not (string-empty-p root))
                   (not (file-remote-p root)))
        (codex-ide-mcp-bridge--deny 'invalid-context
                                    "invalid allowed-root context")))
    roots))

(defun codex-ide-mcp-bridge--resolve-request-path (path &optional allow-missing)
  "Resolve PATH for gateway authorization without exposing it in denials.

When ALLOW-MISSING is non-nil, accept a missing final path component subject
to the same root checks used by the handler sink."
  (condition-case nil
      (codex-ide-mcp-bridge--safe-local-file-path path allow-missing)
    (error
     (codex-ide-mcp-bridge--deny
      'invalid-resource "file resource is not authorized"))))

(defun codex-ide-mcp-bridge--resolve-policy-resources (policy params)
  "Resolve and authorize POLICY resources described by PARAMS."
  (let ((resource (plist-get policy :resource)))
    (pcase resource
      ('buffer
       (let ((buffer (codex-ide-mcp-bridge--buffer-from-params params)))
         (list (codex-ide-mcp-bridge--assert-buffer-authorized buffer policy))))
      ('buffer-or-selected
       (let ((buffer
              (codex-ide-mcp-bridge--buffer-from-params
               params (window-buffer (selected-window)))))
         (list (codex-ide-mcp-bridge--assert-buffer-authorized buffer policy))))
      ('selected-buffer
       (list
        (codex-ide-mcp-bridge--assert-buffer-authorized
         (window-buffer (selected-window)) policy)))
      ('buffers
       (let ((buffers
              (codex-ide-mcp-bridge--buffers-from-search-params params)))
         (dolist (buffer buffers)
           (codex-ide-mcp-bridge--assert-buffer-authorized buffer policy))
         buffers))
      ('all-file-buffers
       (let ((roots
              (codex-ide-mcp-bridge--effective-allowed-root-truenames)))
         (seq-filter
          (lambda (buffer)
            (and (not (codex-ide-mcp-bridge--sensitive-buffer-p buffer))
                 (codex-ide-mcp-bridge--buffer-in-roots-p buffer roots)))
          (buffer-list))))
      ('path
       (list
        (codex-ide-mcp-bridge--resolve-request-path
         (alist-get 'path params))))
      ('path-may-missing
       (list
        (codex-ide-mcp-bridge--resolve-request-path
         (alist-get 'path params) t)))
      ((or 'symbol 'windows) nil)
      ((or 'messages 'minibuffer)
       (unless codex-ide-mcp-bridge-allow-sensitive-state
         (codex-ide-mcp-bridge--deny 'sensitive-disabled
                                     "sensitive editor state is disabled"))
       nil)
      (_
       (codex-ide-mcp-bridge--deny 'invalid-policy
                                   "unsupported resource policy")))))

(defun codex-ide-mcp-bridge--filter-project-files (result roots)
  "Filter buffer entries in RESULT to identities inside ROOTS."
  (let* ((files (append (or (alist-get 'files result) []) nil))
         (scoped
          (seq-filter
           (lambda (item)
             (let* ((name (alist-get 'buffer item))
                    (buffer (and (stringp name) (get-buffer name))))
               (and buffer
                    (not (codex-ide-mcp-bridge--sensitive-buffer-p buffer))
                    (codex-ide-mcp-bridge--buffer-in-roots-p
                     buffer roots))))
           files)))
    (setf (alist-get 'files result)
          (codex-ide-mcp-bridge--json-array scoped))
    result))

(defun codex-ide-mcp-bridge--filter-global-windows (result roots)
  "Redact out-of-scope buffer identities in window RESULT using ROOTS."
  (let ((windows (append (or (alist-get 'windows result) []) nil)))
    (dolist (window windows)
      (let* ((info (alist-get 'buffer-info window))
             (name (alist-get 'buffer info))
             (buffer (and (stringp name) (get-buffer name))))
        (when (and buffer
                   (or (codex-ide-mcp-bridge--sensitive-buffer-p buffer)
                       (not
                        (codex-ide-mcp-bridge--buffer-in-roots-p
                         buffer roots))))
          (setf (alist-get 'buffer-info window)
                (codex-ide-mcp-bridge--buffer-info buffer t)))))
    (setf (alist-get 'windows result)
          (codex-ide-mcp-bridge--json-array windows))
    result))

(defun codex-ide-mcp-bridge--scoped-path-value (path roots)
  "Return (VISIBLE-PATH . SCOPED) for PATH relative to ROOTS."
  (cond
   ((not (stringp path)) (cons :json-null :json-null))
   ((codex-ide-mcp-bridge--path-in-roots-p path roots) (cons path t))
   (t (cons :json-null :json-false))))

(defun codex-ide-mcp-bridge--filter-symbol-paths (result roots)
  "Redact definition paths in RESULT that are outside ROOTS."
  (dolist (field '((function-file . function-file-scoped)
                   (variable-file . variable-file-scoped)))
    (let* ((path-field (car field))
           (scope-field (cdr field))
           (value
            (codex-ide-mcp-bridge--scoped-path-value
             (alist-get path-field result) roots)))
      (setf (alist-get path-field result) (car value))
      (setf (alist-get scope-field result) (cdr value))))
  result)

(defun codex-ide-mcp-bridge--apply-result-filter
    (policy result context)
  "Apply POLICY result filtering to RESULT using CONTEXT."
  (let ((roots
         (codex-ide-mcp-bridge-request-context-allowed-roots context)))
    (pcase (plist-get policy :result-filter)
      ('identity result)
      ('project-files
       (codex-ide-mcp-bridge--filter-project-files result roots))
      ('redact-global-buffers
       (codex-ide-mcp-bridge--filter-global-windows result roots))
      ('redact-symbol-paths
       (codex-ide-mcp-bridge--filter-symbol-paths result roots))
      (_
       (codex-ide-mcp-bridge--deny 'invalid-policy
                                   "unsupported result policy")))))

(defun codex-ide-mcp-bridge--legacy-tool-call (policy params)
  "Dispatch POLICY directly with PARAMS for compatibility comparison."
  (funcall (plist-get policy :handler) params))

(defun codex-ide-mcp-bridge--gateway-tool-call
    (name policy params allowed-roots)
  "Authorize and dispatch NAME with POLICY, PARAMS, and ALLOWED-ROOTS."
  (let* ((context
          (codex-ide-mcp-bridge--make-request-context
           :name name
           :policy policy
           :allowed-roots allowed-roots))
         (codex-ide-mcp-bridge--request-context context))
    (setf (codex-ide-mcp-bridge-request-context-resources context)
          (codex-ide-mcp-bridge--resolve-policy-resources policy params))
    (codex-ide-mcp-bridge--apply-result-filter
     policy
     (funcall (plist-get policy :handler) params)
     context)))

(defun codex-ide-mcp-bridge--tool-call
    (name params &optional allowed-roots)
  "Dispatch bridge tool NAME using PARAMS and ALLOWED-ROOTS."
  (let ((policy (codex-ide-mcp-policy-lookup name)))
    (unless policy
      (codex-ide-mcp-bridge--emit-decision
       name nil 'deny 'unknown-tool)
      (codex-ide-mcp-bridge--deny 'unknown-tool "unknown tool"))
    (condition-case err
        (let ((result
               (pcase codex-ide-mcp-bridge--dispatch-mode
                 ('legacy
                  (codex-ide-mcp-bridge--legacy-tool-call policy params))
                 ('gateway
                  (codex-ide-mcp-bridge--gateway-tool-call
                   name policy params allowed-roots))
                 (_
                  (codex-ide-mcp-bridge--deny
                   'invalid-policy "invalid dispatch mode")))))
          (codex-ide-mcp-bridge--emit-decision
           name policy 'allow 'authorized)
          result)
      (error
       (codex-ide-mcp-bridge--emit-decision
        name policy 'deny
        (if (eq (car err) 'codex-ide-mcp-policy-denied)
            (or (nth 2 err) 'policy-denied)
          'handler-error))
       (signal (car err) (cdr err))))))

;;;###autoload
(defun codex-ide-mcp-bridge--json-tool-catalog ()
  "Return the validated public MCP tool catalog as JSON."
  (codex-ide-mcp-bridge--validate-tool-handlers)
  (json-encode
   (vconcat (codex-ide-mcp-policy-public-catalog))))

;;;###autoload
(defun codex-ide-mcp-bridge--json-tool-call (payload)
  "Decode JSON PAYLOAD, dispatch a bridge tool call, and return JSON."
  (let* ((json-object-type 'alist)
         (json-array-type 'list)
         (json-false :json-false)
         (json-null :json-null)
         (request (json-read-from-string payload))
         (name (alist-get 'name request))
         (params (or (alist-get 'params request) '()))
         (meta (alist-get 'meta request))
         (request-roots (codex-ide-mcp-bridge--request-roots meta))
         (allowed-roots
          (codex-ide-mcp-bridge--canonical-roots
           (append request-roots codex-ide-mcp-bridge-allowed-roots))))
    (unless (stringp name)
      (error "Missing tool name"))
    (unless (listp params)
      (error "Invalid tool params"))
    (let ((codex-ide-mcp-bridge--request-allowed-roots
           request-roots))
      (json-encode
       (codex-ide-mcp-bridge--tool-call
        name params allowed-roots)))))

;; These functions are the Elisp implementations of the MCP bridge commands.

(defun codex-ide-mcp-bridge--resolve-file-buffer (path)
  "Return the buffer visiting PATH, opening it if needed."
  (find-file-noselect (expand-file-name path)))

(defun codex-ide-mcp-bridge--goto-line-and-column (line column)
  "Move point to LINE and COLUMN when provided."
  (goto-char (point-min))
  (when (and (integerp line) (> line 0))
    (forward-line (1- line)))
  (when (and (integerp column) (> column 0))
    (move-to-column (1- column))))

(defun codex-ide-mcp-bridge--find-target-window (origin)
  "Return a non-ORIGIN window, splitting ORIGIN if needed."
  (or (seq-find (lambda (window)
                  (not (eq window origin)))
                (window-list (selected-frame) 'no-minibuf origin))
      (or (ignore-errors (split-window origin nil 'right))
          (ignore-errors (split-window origin nil 'below))
          (let ((split-width-threshold 0)
                (split-height-threshold 0))
            (ignore-errors
              (with-selected-window origin
                (split-window-sensibly origin))))
          (error "Unable to create a window for file buffer view"))))

(defun codex-ide-mcp-bridge--file-buffer-response (buffer &optional extra)
  "Return a bridge response for BUFFER merged with EXTRA."
  (append
   `((path . ,(codex-ide-mcp-bridge--json-nullable
               (buffer-file-name buffer)))
     (buffer . ,(buffer-name buffer))
     (line . ,(with-current-buffer buffer
                (line-number-at-pos)))
     (column . ,(with-current-buffer buffer
                  (1+ (current-column)))))
   extra))

(defun codex-ide-mcp-bridge--tool-call--ensure_file_buffer_open (params)
  "Handle an `ensure_file_buffer_open' bridge request with PARAMS."
  (let ((path (alist-get 'path params))
        buffer
        already-open)
    (setq path (codex-ide-mcp-bridge--safe-local-file-path path))
    (setq already-open (and (find-buffer-visiting path) t))
    (setq buffer (codex-ide-mcp-bridge--resolve-file-buffer path))
    (codex-ide-mcp-bridge--file-buffer-response
     buffer
     `((already-open . ,(codex-ide-mcp-bridge--json-bool already-open))))))

(defun codex-ide-mcp-bridge--tool-call--show_file_buffer (params)
  "Handle a `show_file_buffer' bridge request with PARAMS."
  (let ((path (alist-get 'path params))
        (line (alist-get 'line params))
        (column (alist-get 'column params))
        origin
        target
        buffer)
    (setq path (codex-ide-mcp-bridge--safe-local-file-path path))
    (setq buffer (codex-ide-mcp-bridge--resolve-file-buffer path))
    (setq origin (selected-window))
    (save-selected-window
      (setq target (codex-ide-mcp-bridge--find-target-window origin))
      (set-window-buffer target buffer)
      (with-selected-window target
        (codex-ide-mcp-bridge--goto-line-and-column line column)))
    (codex-ide-mcp-bridge--file-buffer-response
     buffer
     `((window-id . ,(format "%s" target))))))

(defun codex-ide-mcp-bridge--tool-call--kill_file_buffer (params)
  "Handle a `kill_file_buffer' bridge request with PARAMS."
  (let* ((path (alist-get 'path params))
         (expanded-path (and (stringp path)
                             (not (string-empty-p path))
                             (codex-ide-mcp-bridge--safe-local-file-path
                              path
                              t)))
         (buffer (and expanded-path
                      (find-buffer-visiting expanded-path))))
    (unless expanded-path
      (error "Missing file path"))
    (if (not buffer)
        `((path . ,expanded-path)
          (buffer . :json-null)
          (killed . :json-false))
      (let ((buffer-name (buffer-name buffer))
            (killed (kill-buffer buffer)))
        `((path . ,expanded-path)
          (buffer . ,(codex-ide-mcp-bridge--json-nullable buffer-name))
          (killed . ,(codex-ide-mcp-bridge--json-bool killed)))))))

(defun codex-ide-mcp-bridge--tool-call--lisp_check_parens (params)
  "Handle a `lisp_check_parens' bridge request with PARAMS."
  (let ((path (alist-get 'path params)))
    (setq path (codex-ide-mcp-bridge--safe-local-file-path path))
    (with-current-buffer (codex-ide-mcp-bridge--resolve-file-buffer path)
      (save-mark-and-excursion
        (save-restriction
          (widen)
          (let ((inhibit-message t))
            (condition-case err
                (progn
                  (check-parens)
                  `((path . ,path)
                    (balanced . t)
                    (mismatch . :json-false)))
              (user-error
               (let ((mismatch-point (point)))
                 `((path . ,path)
                   (balanced . :json-false)
                   (mismatch . t)
                   (point . ,mismatch-point)
                   (line . ,(line-number-at-pos mismatch-point))
                   (column . ,(save-excursion
                                (goto-char mismatch-point)
                                (1+ (current-column))))
                   (message . ,(error-message-string err))))))))))))

(defun codex-ide-mcp-bridge--tool-call--get_all_buffers (_params)
  "Handle a `get_all_buffers' bridge request."
  (let ((buffers
         (if codex-ide-mcp-bridge--request-context
             (codex-ide-mcp-bridge-request-context-resources
              codex-ide-mcp-bridge--request-context)
           (buffer-list))))
    `((files . ,(codex-ide-mcp-bridge--json-array
                 (mapcar #'codex-ide-mcp-bridge--buffer-info
                         buffers))))))

(defun codex-ide-mcp-bridge--tool-call--get_buffer_info (params)
  "Handle a `get_buffer_info' bridge request with PARAMS."
  (let* ((buffer-name (alist-get 'buffer params))
         (buffer (and (stringp buffer-name)
                      (get-buffer buffer-name))))
    (unless buffer
      (error "Unknown buffer: %s" (or buffer-name "nil")))
    (codex-ide-mcp-bridge--assert-buffer-for-tool
     buffer "emacs_get_buffer_info")
    (codex-ide-mcp-bridge--buffer-info buffer)))

(defun codex-ide-mcp-bridge--tool-call--get_buffer_text (params)
  "Handle a `get_buffer_text' bridge request with PARAMS."
  (let* ((buffer-name (alist-get 'buffer params))
         (buffer (and (stringp buffer-name)
                      (get-buffer buffer-name))))
    (unless buffer
      (error "Unknown buffer: %s" (or buffer-name "nil")))
    (codex-ide-mcp-bridge--assert-buffer-for-tool
     buffer "emacs_get_buffer_text")
    (codex-ide-mcp-bridge--assert-buffer-file-readable buffer)
    (with-current-buffer buffer
      (let* ((limit (if (and (integerp codex-ide-mcp-bridge-buffer-text-limit)
                             (>= codex-ide-mcp-bridge-buffer-text-limit 0))
                        codex-ide-mcp-bridge-buffer-text-limit
                      codex-ide-mcp-bridge-buffer-slice-text-limit))
             (end (min (point-max) (+ (point-min) limit)))
             (truncated (< end (point-max))))
        `((buffer . ,(buffer-name buffer))
          (text-truncated . ,(codex-ide-mcp-bridge--json-bool truncated))
          (text . ,(buffer-substring-no-properties (point-min) end)))))))

(defun codex-ide-mcp-bridge--tool-call--get_buffer_diagnostics (params)
  "Handle a `get_buffer_diagnostics' bridge request with PARAMS."
  (let* ((buffer-name (alist-get 'buffer params))
         (buffer (and (stringp buffer-name)
                      (get-buffer buffer-name))))
    (unless buffer
      (error "Unknown buffer: %s" (or buffer-name "nil")))
    (codex-ide-mcp-bridge--assert-buffer-for-tool
     buffer "emacs_get_buffer_diagnostics")
    (with-current-buffer buffer
      `((buffer . ,(buffer-name buffer))
        (file . ,(codex-ide-mcp-bridge--json-nullable
                  (when-let* ((file (buffer-file-name buffer)))
                    (expand-file-name file))))
        (diagnostics . ,(codex-ide-mcp-bridge--json-array
                         (or (codex-ide-mcp-bridge--flymake-diagnostics)
                             (codex-ide-mcp-bridge--flycheck-diagnostics)
                             '())))))))

(defun codex-ide-mcp-bridge--tool-call--get_current_context (_params)
  "Handle a `get_current_context' bridge request."
  (let* ((window (selected-window))
         (buffer (window-buffer window)))
    (codex-ide-mcp-bridge--assert-buffer-for-tool
     buffer "emacs_get_current_context")
    (with-current-buffer buffer
      `((window-id . ,(format "%s" window))
        (buffer-info . ,(codex-ide-mcp-bridge--buffer-info buffer))
        (point . ,(codex-ide-mcp-bridge--point-location))
        (mark . ,(if (mark t)
                     `((point . ,(mark t))
                       (line . ,(line-number-at-pos (mark t)))
                       (column . ,(save-excursion
                                    (goto-char (mark t))
                                    (1+ (current-column)))))
                   :json-null))
        (region . ,(codex-ide-mcp-bridge--region-info))
        (visible . ((start . ,(window-start window))
                    (end . ,(window-end window t))
                    (start-line . ,(line-number-at-pos (window-start window)))
                    (end-line . ,(line-number-at-pos (window-end window t)))))
        (project-root . ,(codex-ide-mcp-bridge--json-nullable
                          (codex-ide-mcp-bridge--project-root)))))))

(defun codex-ide-mcp-bridge--tool-call--get_buffer_slice (params)
  "Handle a `get_buffer_slice' bridge request with PARAMS."
  (let* ((buffer (codex-ide-mcp-bridge--buffer-from-params params))
         (around-point (alist-get 'around-point params))
         (requested-start (alist-get 'start-line params))
         (requested-end (alist-get 'end-line params)))
    (codex-ide-mcp-bridge--assert-buffer-for-tool
     buffer "emacs_get_buffer_slice")
    (codex-ide-mcp-bridge--assert-buffer-file-readable buffer)
    (with-current-buffer buffer
      (save-excursion
        (let* ((line-count (line-number-at-pos (point-max)))
               (current-line (line-number-at-pos))
               (start-line (cond
                            ((integerp around-point)
                             (max 1 (- current-line around-point)))
                            ((integerp requested-start) requested-start)
                            (t 1)))
               (end-line (cond
                          ((integerp around-point)
                           (min line-count (+ current-line around-point)))
                          ((integerp requested-end) requested-end)
                          (t (min line-count (+ start-line 199)))))
               (start-line (max 1 (min start-line line-count)))
               (end-line (max start-line (min end-line line-count)))
               (start-pos (progn
                            (goto-char (point-min))
                            (forward-line (1- start-line))
                            (point)))
               (requested-end-pos (codex-ide-mcp-bridge--goto-line-end-inclusive end-line))
               (limit (max 0 codex-ide-mcp-bridge-buffer-slice-text-limit))
               (end-pos (min requested-end-pos (+ start-pos limit)))
               (truncated (< end-pos requested-end-pos)))
          `((buffer . ,(buffer-name buffer))
            (start-line . ,start-line)
            (end-line . ,end-line)
            (line-count . ,line-count)
            (text-truncated . ,(codex-ide-mcp-bridge--json-bool truncated))
            (text . ,(buffer-substring-no-properties start-pos end-pos))))))))

(defun codex-ide-mcp-bridge--tool-call--get_region_text (params)
  "Handle a `get_region_text' bridge request with PARAMS."
  (let ((buffer (codex-ide-mcp-bridge--buffer-from-params params (window-buffer (selected-window)))))
    (codex-ide-mcp-bridge--assert-buffer-for-tool
     buffer "emacs_get_region_text")
    (codex-ide-mcp-bridge--assert-buffer-file-readable buffer)
    (with-current-buffer buffer
      (append
       `((buffer . ,(buffer-name buffer)))
       (codex-ide-mcp-bridge--region-info)))))

(defun codex-ide-mcp-bridge--buffers-from-search-params (params)
  "Return the list of buffers named by search PARAMS."
  (let ((buffer-names (alist-get 'buffers params)))
    (unless (and (listp buffer-names) buffer-names)
      (error "Missing search buffers"))
    (mapcar
     (lambda (buffer-name)
       (unless (and (stringp buffer-name) (not (string-empty-p buffer-name)))
         (error "Invalid search buffer name: %S" buffer-name))
       (or (get-buffer buffer-name)
           (error "Unknown buffer: %s" buffer-name)))
     buffer-names)))

(defun codex-ide-mcp-bridge--tool-call--search_buffers (params)
  "Handle a `search_buffers' bridge request with PARAMS."
  (let* ((pattern (alist-get 'pattern params))
         (buffers (codex-ide-mcp-bridge--buffers-from-search-params params))
         (regexp (eq (alist-get 'regexp params) t))
         (max-results (or (alist-get 'max-results params) 100))
         (needle (and (stringp pattern)
                      (if regexp pattern (regexp-quote pattern))))
         (results nil))
    (unless (and (stringp pattern) (not (string-empty-p pattern)))
      (error "Missing search pattern"))
    (dolist (buffer buffers)
      (when (< (length results) max-results)
        (codex-ide-mcp-bridge--assert-buffer-for-tool
         buffer "emacs_search_buffers")
        (codex-ide-mcp-bridge--assert-buffer-file-readable buffer)
        (with-current-buffer buffer
          (when needle
            (save-excursion
              (goto-char (point-min))
              (while (and (< (length results) max-results)
                          (re-search-forward needle nil t))
                (let* ((match-start (match-beginning 0))
                       (line-info
                        (codex-ide-mcp-bridge--bounded-line-text-at-point
                         match-start
                         codex-ide-mcp-bridge-search-result-text-limit)))
                  (push (append
                         `((buffer . ,(buffer-name buffer))
                           (file . ,(codex-ide-mcp-bridge--json-nullable
                                     (when-let* ((file (buffer-file-name buffer)))
                                       (expand-file-name file))))
                           (line . ,(line-number-at-pos match-start))
                           (column . ,(save-excursion
                                        (goto-char match-start)
                                        (1+ (current-column))))
                           (match . ,(match-string-no-properties 0)))
                         line-info)
                        results))))))))
    `((pattern . ,pattern)
      (regexp . ,(codex-ide-mcp-bridge--json-bool regexp))
      (truncated . ,(codex-ide-mcp-bridge--json-bool
                     (>= (length results) max-results)))
      (results . ,(codex-ide-mcp-bridge--json-array (nreverse results))))))

(defun codex-ide-mcp-bridge--tool-call--get_symbol_at_point (params)
  "Handle a `get_symbol_at_point' bridge request with PARAMS."
  (let ((buffer (codex-ide-mcp-bridge--buffer-from-params params (window-buffer (selected-window)))))
    (codex-ide-mcp-bridge--assert-buffer-for-tool
     buffer "emacs_get_symbol_at_point")
    (with-current-buffer buffer
      (let* ((bounds (bounds-of-thing-at-point 'symbol))
             (symbol (thing-at-point 'symbol t)))
        `((buffer . ,(buffer-name buffer))
          (symbol . ,(codex-ide-mcp-bridge--json-nullable symbol))
          (start . ,(if bounds (car bounds) :json-null))
          (end . ,(if bounds (cdr bounds) :json-null))
          (line . ,(line-number-at-pos))
          (column . ,(1+ (current-column))))))))

(defun codex-ide-mcp-bridge--tool-call--describe_symbol (params)
  "Handle a `describe_symbol' bridge request with PARAMS."
  (let* ((symbol-name (alist-get 'symbol params))
         (type (or (alist-get 'type params) "any"))
         (symbol (and (stringp symbol-name) (intern-soft symbol-name))))
    (unless (and (stringp symbol-name) (not (string-empty-p symbol-name)))
      (error "Missing symbol"))
    (let* ((functionp (and symbol (fboundp symbol)))
           (variablep (and symbol (boundp symbol)))
           (facep (and symbol (facep symbol))))
      `((symbol . ,symbol-name)
        (exists . ,(codex-ide-mcp-bridge--json-bool symbol))
        (function . ,(codex-ide-mcp-bridge--json-bool functionp))
        (variable . ,(codex-ide-mcp-bridge--json-bool variablep))
        (face . ,(codex-ide-mcp-bridge--json-bool facep))
        (function-documentation . ,(codex-ide-mcp-bridge--json-nullable
                                    (when (and functionp
                                               (member type '("any" "function")))
                                      (documentation symbol t))))
        (variable-documentation . ,(codex-ide-mcp-bridge--json-nullable
                                    (when (and variablep
                                               (member type '("any" "variable")))
                                      (documentation-property symbol
                                                              'variable-documentation
                                                              t))))
        (function-file . ,(codex-ide-mcp-bridge--json-nullable
                           (when functionp (symbol-file symbol 'defun))))
        (variable-file . ,(codex-ide-mcp-bridge--json-nullable
                           (when variablep (symbol-file symbol 'defvar))))))))

(defun codex-ide-mcp-bridge--tool-call--get_messages (params)
  "Handle a `get_messages' bridge request with PARAMS."
  (unless codex-ide-mcp-bridge-allow-sensitive-state
    (error "Sensitive Emacs state bridge tools are disabled"))
  (let* ((max-lines (or (alist-get 'max-lines params) 200))
         (buffer (get-buffer "*Messages*")))
    (if (not buffer)
        '((buffer . "*Messages*")
          (available . :json-false)
          (text . ""))
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-max))
          (forward-line (- max-lines))
          `((buffer . ,(buffer-name buffer))
            (available . t)
            (text . ,(buffer-substring-no-properties (point) (point-max)))))))))

(defun codex-ide-mcp-bridge--tool-call--get_minibuffer_state (_params)
  "Handle a `get_minibuffer_state' bridge request."
  (let* ((window (active-minibuffer-window))
         (buffer (and window (window-buffer window))))
    (if (not buffer)
        '((active . :json-false)
          (buffer . :json-null)
          (prompt . :json-null)
          (input . :json-null))
      (unless codex-ide-mcp-bridge-allow-sensitive-state
        (error "Sensitive Emacs state bridge tools are disabled"))
      (with-current-buffer buffer
        `((active . t)
          (buffer . ,(buffer-name buffer))
          (prompt . ,(minibuffer-prompt))
          (input . ,(minibuffer-contents-no-properties)))))))

(defun codex-ide-mcp-bridge--tool-call--get_all_windows (_params)
  "Handle a `get_all_windows' bridge request."
  (let ((windows
         (mapcar
          (lambda (window)
            (let ((buffer (window-buffer window)))
              `((window-id . ,(format "%s" window))
                (selected . ,(codex-ide-mcp-bridge--json-bool
                              (eq window (selected-window))))
                (dedicated . ,(codex-ide-mcp-bridge--json-bool
                               (window-dedicated-p window)))
                (point . ,(window-point window))
                (start . ,(window-start window))
                (edges . ,(append (window-edges window) nil))
                (buffer-info . ,(codex-ide-mcp-bridge--buffer-info buffer)))))
          (window-list (selected-frame) 'no-minibuf (frame-first-window)))))
    `((windows . ,(codex-ide-mcp-bridge--json-array windows)))))

(codex-ide-mcp-bridge--validate-tool-handlers)

(provide 'codex-ide-mcp-bridge)

;;; codex-ide-mcp-bridge.el ends here
