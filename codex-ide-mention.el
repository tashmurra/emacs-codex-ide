;;; codex-ide-mention.el --- Prompt mention completion for codex-ide -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; This module owns prompt mention completion.  The only implemented provider
;; today is `$skill'.  The provider shape intentionally leaves room for future
;; file, directory, and plugin mentions without turning those into local Emacs
;; commands.  Mentions remain prompt text and are interpreted by Codex when the
;; normal prompt submission path sends a turn to app-server.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'codex-ide-core)
(require 'codex-ide-protocol)

(declare-function codex-ide-log-message "codex-ide-log" (session format-string &rest args))

(defgroup codex-ide-mention nil
  "Prompt mention completion for Codex IDE prompts."
  :group 'codex-ide)

;;;###autoload
(defcustom codex-ide-mention-allow-uncached-skill-paths nil
  "Whether linked skill mentions may use paths absent from the skill cache.

When nil, linked or history-decoded `$skill' mentions only become structured
skill input items when their target path matches a cached skill.  Mentions
selected through completion keep their recorded binding even before a refreshed
cache is available."
  :type 'boolean
  :group 'codex-ide-mention)

(defconst codex-ide-mention--skill-sigil "$")

(defconst codex-ide-mention--providers
  '((skill :sigil "$" :implemented t)
    (file :sigil "@" :implemented nil)
    (directory :sigil "@" :implemented nil)
    (plugin :sigil "@" :implemented nil))
  "Mention providers known to the prompt mention layer.
Only the `skill' provider is implemented.  The remaining entries reserve the
shape for future `@' mentions without enabling completion or parsing behavior.")

(defconst codex-ide-mention--skills-cache-key :skills-list)
(defconst codex-ide-mention--skills-cache-errors-key :skills-list-errors)
(defconst codex-ide-mention--skills-cache-state-key :skills-list-state)
(defconst codex-ide-mention--skills-cache-token-key :skills-list-token)
(defconst codex-ide-mention--skills-cache-fetched-at-key
  :skills-list-fetched-at)
(defconst codex-ide-mention--binding-property
  'codex-ide-mention-binding
  "Text property used to remember a selected mention binding.")
(defconst codex-ide-mention--common-env-vars
  '("PATH" "HOME" "USER" "SHELL" "PWD" "TMPDIR" "TEMP" "TMP" "LANG"
    "TERM" "XDG_CONFIG_HOME")
  "Environment variable names ignored by `$' mention parsing.")

(defun codex-ide-mention--current-session ()
  "Return the current Codex session for mention completion, or nil."
  (or (and (boundp 'codex-ide--session)
           (codex-ide-session-p codex-ide--session)
           codex-ide--session)
      (codex-ide--get-default-session-for-current-buffer)))

(defun codex-ide-mention--as-list (value)
  "Return VALUE as a list."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t nil)))

(defun codex-ide-mention--skill-enabled-p (skill)
  "Return non-nil when SKILL should be offered in completion."
  (not (memq (alist-get 'enabled skill) '(nil :json-false))))

(defun codex-ide-mention--normalize-skills-response (result)
  "Return normalized skill cache data from app-server RESULT."
  (let (skills errors)
    (dolist (entry (codex-ide-mention--as-list
                    (alist-get 'data result)))
      (setq errors
            (append (codex-ide-mention--as-list
                     (alist-get 'errors entry))
                    errors))
      (dolist (skill (codex-ide-mention--as-list
                      (alist-get 'skills entry)))
        (when (and (codex-ide-mention--skill-enabled-p skill)
                   (stringp (alist-get 'name skill))
                   (not (string-empty-p (alist-get 'name skill))))
          (push skill skills))))
    (list :skills (nreverse skills)
          :errors (nreverse errors))))

(defun codex-ide-mention--store-skill-cache (session result)
  "Store app-server skills RESULT in SESSION metadata."
  (let* ((normalized (codex-ide-mention--normalize-skills-response result))
         (skills (plist-get normalized :skills))
         (errors (plist-get normalized :errors)))
    (codex-ide--session-metadata-put
     session
     codex-ide-mention--skills-cache-key
     skills)
    (codex-ide--session-metadata-put
     session
     codex-ide-mention--skills-cache-errors-key
     errors)
    (codex-ide--session-metadata-put
     session
     codex-ide-mention--skills-cache-state-key
     'ready)
    (codex-ide--session-metadata-put
     session
     codex-ide-mention--skills-cache-fetched-at-key
     (float-time))
    (codex-ide-log-message
     session
     "Skill completion cache refreshed: %d skills%s"
     (length skills)
     (if errors
         (format ", %d errors" (length errors))
       ""))))

(defun codex-ide-mention-refresh-skill-cache (&optional session force-reload)
  "Refresh SESSION's skill completion cache asynchronously.
When FORCE-RELOAD is non-nil, ask app-server to re-scan skills from disk."
  (setq session (or session (codex-ide-mention--current-session)))
  (when (and session
             (process-live-p (codex-ide-session-process session)))
    (let ((token (list 'skills-list (float-time))))
      (codex-ide--session-metadata-put
       session
       codex-ide-mention--skills-cache-token-key
       token)
      (codex-ide--session-metadata-put
       session
       codex-ide-mention--skills-cache-state-key
       'loading)
      (codex-ide-log-message
       session
       "Refreshing skill completion cache%s"
       (if force-reload " with forceReload" ""))
      (codex-ide--list-skills-async
       session
       force-reload
       (lambda (result error)
         (when (eq (codex-ide--session-metadata-get
                    session
                    codex-ide-mention--skills-cache-token-key)
                   token)
           (codex-ide--session-metadata-put
            session
            codex-ide-mention--skills-cache-token-key
            nil)
           (if error
               (progn
                 (codex-ide--session-metadata-put
                  session
                  codex-ide-mention--skills-cache-state-key
                  'error)
                 (codex-ide-log-message
                  session
                  "Skill completion cache refresh failed: %s"
                  (or (alist-get 'message error)
                      (format "%S" error))))
             (codex-ide-mention--store-skill-cache session result))))))))

(defun codex-ide-mention-invalidate-skill-cache (&optional session)
  "Mark SESSION's skill completion cache stale."
  (setq session (or session (codex-ide-mention--current-session)))
  (when session
    (codex-ide--session-metadata-put
     session
     codex-ide-mention--skills-cache-state-key
     'stale)))

(defun codex-ide-mention-refresh-skill-cache-after-change (&optional session)
  "Refresh SESSION's skill completion cache after a `skills/changed' event."
  (setq session (or session (codex-ide-mention--current-session)))
  (when session
    (codex-ide-mention-invalidate-skill-cache session)
    (codex-ide-mention-refresh-skill-cache session t)))

(defun codex-ide-mention--cached-skills (&optional session)
  "Return cached skills for SESSION, triggering a background fetch if needed."
  (setq session (or session (codex-ide-mention--current-session)))
  (when session
    (let ((state (codex-ide--session-metadata-get
                  session
                  codex-ide-mention--skills-cache-state-key)))
      (when (or (null state) (eq state 'stale))
        (codex-ide-mention-refresh-skill-cache
         session
         (eq state 'stale))))
    (codex-ide--session-metadata-get
     session
     codex-ide-mention--skills-cache-key)))

(defun codex-ide-mention--stored-skills (&optional session)
  "Return cached skills for SESSION without triggering a background fetch."
  (setq session (or session (codex-ide-mention--current-session)))
  (when session
    (codex-ide--session-metadata-get
     session
     codex-ide-mention--skills-cache-key)))

(defun codex-ide-mention--available-skills (&optional session)
  "Return enabled cached skills for SESSION."
  (seq-filter #'codex-ide-mention--skill-enabled-p
              (codex-ide-mention--cached-skills session)))

(defun codex-ide-mention--available-stored-skills (&optional session)
  "Return enabled cached skills for SESSION without triggering a fetch."
  (seq-filter #'codex-ide-mention--skill-enabled-p
              (codex-ide-mention--stored-skills session)))

(defun codex-ide-mention--skill-description (skill)
  "Return a completion annotation description for SKILL."
  (let ((interface (alist-get 'interface skill)))
    (or (and (listp interface)
             (alist-get 'shortDescription interface))
        (alist-get 'shortDescription skill)
        (alist-get 'description skill))))

(defun codex-ide-mention--skill-names (&optional session)
  "Return skill names available for `$' mention completion."
  (delete-dups
   (delq nil
         (mapcar (lambda (skill)
                   (alist-get 'name skill))
                 (copy-sequence
                  (codex-ide-mention--available-skills session))))))

(defun codex-ide-mention--skill-lookup (name &optional session)
  "Return the first cached skill named NAME for SESSION, or nil."
  (cl-find name
           (codex-ide-mention--available-skills session)
           :key (lambda (skill)
                  (alist-get 'name skill))
           :test #'string=))

(defun codex-ide-mention--skill-path (skill)
  "Return SKILL's path, or nil."
  (let ((path (alist-get 'path skill)))
    (and (stringp path)
         (not (string-empty-p path))
         path)))

(defun codex-ide-mention--normalize-skill-path (path)
  "Return normalized skill PATH for comparisons."
  (and (stringp path)
       (string-remove-prefix "skill://" path)))

(defun codex-ide-mention--skill-path-p (path)
  "Return non-nil when PATH denotes a skill mention target."
  (and (stringp path)
       (not (string-empty-p path))
       (not (string-prefix-p "app://" path))
       (not (string-prefix-p "mcp://" path))
       (not (string-prefix-p "plugin://" path))))

(defun codex-ide-mention--skill-file-path-p (path)
  "Return non-nil when PATH has the expected on-disk skill file shape."
  (let ((normalized (codex-ide-mention--normalize-skill-path path)))
    (and (stringp normalized)
         (or (string-prefix-p "skill://" path)
             (and (file-name-absolute-p normalized)
                  (string= (file-name-nondirectory normalized)
                           "SKILL.md"))))))

(defun codex-ide-mention--known-skill-path-p (path session)
  "Return non-nil when PATH matches a cached skill path for SESSION."
  (let ((normalized (codex-ide-mention--normalize-skill-path path)))
    (and session
         (stringp normalized)
         (seq-some
          (lambda (skill)
            (when-let* ((skill-path (codex-ide-mention--skill-path skill)))
              (equal normalized
                     (codex-ide-mention--normalize-skill-path skill-path))))
          (codex-ide-mention--available-stored-skills session)))))

(defun codex-ide-mention--linked-skill-mention-p (mention &optional session)
  "Return non-nil when MENTION safely names a skill target."
  (let ((path (plist-get mention :path)))
    (and (equal (plist-get mention :sigil) codex-ide-mention--skill-sigil)
         (eq (plist-get mention :kind) 'skill)
         (codex-ide-mention--skill-path-p path)
         (or (codex-ide-mention--known-skill-path-p path session)
             (and codex-ide-mention-allow-uncached-skill-paths
                  (codex-ide-mention--skill-file-path-p path))))))

(defun codex-ide-mention--encoded-skill-mention-p (mention &optional session)
  "Return non-nil when MENTION is safe to decode as an encoded skill mention."
  (codex-ide-mention--linked-skill-mention-p mention session))

(defun codex-ide-mention--name-char-p (char)
  "Return non-nil when CHAR is valid in a mention name."
  (and char
       (or (and (>= char ?a) (<= char ?z))
           (and (>= char ?A) (<= char ?Z))
           (and (>= char ?0) (<= char ?9))
           (eq char ?_)
           (eq char ?-))))

(defun codex-ide-mention--common-env-var-p (name)
  "Return non-nil when NAME is a common environment variable."
  (member (upcase name) codex-ide-mention--common-env-vars))

(defun codex-ide-mention--skill-input-item (skill)
  "Return a structured app-server input item for SKILL."
  (when-let* ((name (alist-get 'name skill))
              (path (codex-ide-mention--skill-path skill)))
    `((type . "skill")
      (name . ,name)
      (path . ,path))))

(defun codex-ide-mention--mention-skill (mention)
  "Return a minimal skill alist for a path-specific MENTION."
  (when-let* ((name (plist-get mention :name))
              (path (plist-get mention :path)))
    `((name . ,name)
      (path . ,path)
      (enabled . t))))

(defun codex-ide-mention--history-path-encode (path)
  "Return PATH encoded for a history Markdown link target."
  (mapconcat
   (lambda (char)
     (if (memq char '(?% ?\( ?\) ?\s ?\t ?\n ?\r))
         (format "%%%02X" char)
       (char-to-string char)))
   path
   ""))

(defun codex-ide-mention--history-path-decode (path)
  "Return history Markdown link PATH with percent escapes decoded."
  (let ((index 0)
        (out ""))
    (while (< index (length path))
      (if (and (eq (aref path index) ?%)
               (< (+ index 2) (length path)))
          (let ((hex (substring path (1+ index) (+ index 3))))
            (if (string-match-p "\\`[[:xdigit:]][[:xdigit:]]\\'" hex)
                (setq out (concat out
                                  (char-to-string
                                   (string-to-number hex 16)))
                      index (+ index 3))
              (setq out (concat out "%")
                    index (1+ index))))
        (setq out (concat out (char-to-string (aref path index)))
              index (1+ index))))
    out))

(defun codex-ide-mention--skills-by-path (skills)
  "Return hash table mapping normalized skill paths to SKILLS."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (skill skills)
      (when-let* ((path (codex-ide-mention--skill-path skill)))
        (puthash (codex-ide-mention--normalize-skill-path path)
                 skill
                 table)))
    table))

(defun codex-ide-mention--binding-at (text start name)
  "Return valid skill mention binding on TEXT at START for NAME, or nil."
  (let ((binding (get-text-property
                  start
                  codex-ide-mention--binding-property
                  text)))
    (when (and (consp binding)
               (equal (plist-get binding :sigil)
                      codex-ide-mention--skill-sigil)
               (eq (plist-get binding :kind) 'skill)
               (equal (plist-get binding :name) name)
               (codex-ide-mention--skill-path-p
                (plist-get binding :path)))
      binding)))

(defun codex-ide-mention--parse-linked-mention-at (text start)
  "Return linked mention at START in TEXT, or nil.
The return value is a plist with :sigil, :kind, :name, :path, :start, and
:end.  Only linked skill mentions are parsed today."
  (when (and (< (1+ start) (length text))
             (eq (aref text start) ?\[)
             (eq (aref text (1+ start)) ?$))
    (let ((name-start (+ start 2))
          name-end)
      (when (and (< name-start (length text))
                 (codex-ide-mention--name-char-p
                  (aref text name-start)))
        (setq name-end (1+ name-start))
        (while (and (< name-end (length text))
                    (codex-ide-mention--name-char-p
                     (aref text name-end)))
          (setq name-end (1+ name-end)))
        (when (and (< name-end (length text))
                   (eq (aref text name-end) ?\]))
          (let ((path-start (1+ name-end)))
            (while (and (< path-start (length text))
                        (memq (aref text path-start) '(?\s ?\t ?\n ?\r)))
              (setq path-start (1+ path-start)))
            (when (and (< path-start (length text))
                       (eq (aref text path-start) ?\())
              (let ((path-end (1+ path-start)))
                (while (and (< path-end (length text))
                            (not (eq (aref text path-end) ?\))))
                  (setq path-end (1+ path-end)))
                (when (and (< path-end (length text))
                           (eq (aref text path-end) ?\)))
                  (let ((path (string-trim
                               (substring text (1+ path-start) path-end))))
                    (unless (string-empty-p path)
                      (list :sigil codex-ide-mention--skill-sigil
                            :kind 'skill
                            :name (substring text name-start name-end)
                            :path (codex-ide-mention--history-path-decode
                                   path)
                            :start start
                            :end (1+ path-end)))))))))))))

(defun codex-ide-mention--collect-mentions (text &optional session)
  "Return supported mentions found in TEXT.
Mentions are represented as plists.  The parser follows Codex TUI mention
syntax for plain `$name' and linked `[$name](path)' skill mentions.  Future
`@' file, directory, and plugin mentions are intentionally not parsed yet.
SESSION is used to distinguish linked skill mentions from ordinary Markdown
links whose labels happen to start with `$'."
  (let ((index 0)
        mentions)
    (while (< index (length text))
      (let ((char (aref text index)))
        (cond
         ((and (eq char ?\[)
               (codex-ide-mention--parse-linked-mention-at text index))
          (let ((mention (codex-ide-mention--parse-linked-mention-at
                          text
                          index)))
            (when (codex-ide-mention--linked-skill-mention-p
                   mention
                   session)
              (push (plist-put mention :source 'linked) mentions))
            (setq index (plist-get mention :end))))
         ((eq char ?$)
          (let ((name-start (1+ index)))
            (if (or (>= name-start (length text))
                    (not (codex-ide-mention--name-char-p
                          (aref text name-start))))
                (setq index (1+ index))
              (let ((name-end (1+ name-start)))
                (while (and (< name-end (length text))
                            (codex-ide-mention--name-char-p
                             (aref text name-end)))
                  (setq name-end (1+ name-end)))
                (let ((name (substring-no-properties
                             (substring text name-start name-end))))
                  (let ((binding
                         (codex-ide-mention--binding-at
                          text
                          index
                          name)))
                    (unless (and (not binding)
                                 (codex-ide-mention--common-env-var-p name))
                      (push (list :sigil codex-ide-mention--skill-sigil
                                  :kind 'skill
                                  :name name
                                  :path (plist-get binding :path)
                                  :binding binding
                                  :source (if binding 'binding 'plain)
                                  :start index
                                  :end name-end)
                            mentions))))
                (setq index name-end)))))
         (t
          (setq index (1+ index))))))
    (nreverse mentions)))

(defun codex-ide-mention--session-input-with-properties (session prompt)
  "Return SESSION's current input with text properties when it matches PROMPT."
  (when-let* ((start (codex-ide-mention--input-start-position session))
              (end (codex-ide-mention--input-end-position session))
              (buffer (and session (codex-ide-session-buffer session))))
    (when (and (buffer-live-p buffer)
               (<= start end))
      (with-current-buffer buffer
        (let ((text (codex-ide-mention--string-trim-right
                     (buffer-substring start end))))
          (when (string= (substring-no-properties text) prompt)
            text))))))

(defun codex-ide-mention--string-trim-right (text)
  "Return TEXT without trailing whitespace, preserving text properties."
  (if (string-match "[[:space:]\n\r\t]+\\'" text)
      (substring text 0 (match-beginning 0))
    text))

(defun codex-ide-mention--source-text (prompt &optional session)
  "Return PROMPT with mention binding properties when available."
  (or (and session
           (codex-ide-mention--session-input-with-properties
            session
            prompt))
      prompt))

(defun codex-ide-mention--resolve-mentions (mentions skills)
  "Resolve MENTIONS against SKILLS using Codex TUI ordering semantics."
  (let* ((skills-by-path (codex-ide-mention--skills-by-path skills))
         (seen-paths (make-hash-table :test 'equal))
         (seen-names (make-hash-table :test 'equal))
         (binding-names (make-hash-table :test 'equal))
         (linked-paths (make-hash-table :test 'equal))
         linked-mentions
         (plain-names (make-hash-table :test 'equal))
         resolved)
    (dolist (mention mentions)
      (pcase (plist-get mention :source)
        ('binding
         (let* ((name (plist-get mention :name))
                (mention-path (plist-get mention :path))
                (path (codex-ide-mention--normalize-skill-path
                       mention-path))
                (skill (and path (gethash path skills-by-path)))
                (resolved-skill
                 (or skill
                     (codex-ide-mention--mention-skill mention)))
                (skill-path (or (codex-ide-mention--skill-path skill)
                                mention-path)))
           (when name
             (puthash name t binding-names))
           (when (and resolved-skill skill-path)
             (let ((normalized (codex-ide-mention--normalize-skill-path
                                skill-path)))
               (unless (gethash normalized seen-paths)
                 (puthash normalized t seen-paths)
                 (when-let* ((skill-name (alist-get 'name resolved-skill)))
                   (puthash skill-name t seen-names))
                 (push resolved-skill resolved))))))
        ('linked
         (when-let* ((mention-path (plist-get mention :path))
                     (path (codex-ide-mention--normalize-skill-path
                            mention-path)))
           (unless (gethash path linked-paths)
             (push mention linked-mentions))
           (puthash path t linked-paths)))
        (_
         (puthash (plist-get mention :name) t plain-names))))
    (dolist (skill skills)
      (when-let* ((path (codex-ide-mention--skill-path skill))
                  (normalized (codex-ide-mention--normalize-skill-path
                               path)))
        (when (and (gethash normalized linked-paths)
                   (not (gethash normalized seen-paths)))
          (puthash normalized t seen-paths)
          (puthash (alist-get 'name skill) t seen-names)
          (push skill resolved))))
    (dolist (mention (nreverse linked-mentions))
      (when-let* ((mention-path (plist-get mention :path))
                  (normalized (codex-ide-mention--normalize-skill-path
                               mention-path))
                  (skill (codex-ide-mention--mention-skill mention)))
        (unless (gethash normalized seen-paths)
          (puthash normalized t seen-paths)
          (when-let* ((skill-name (alist-get 'name skill)))
            (puthash skill-name t seen-names))
          (push skill resolved))))
    (dolist (skill skills)
      (let ((name (alist-get 'name skill))
            (path (codex-ide-mention--skill-path skill)))
        (when (and name
                   path
                   (gethash name plain-names)
                   (not (gethash name binding-names))
                   (not (gethash name seen-names))
                   (not (gethash
                         (codex-ide-mention--normalize-skill-path path)
                         seen-paths)))
          (puthash name t seen-names)
          (puthash (codex-ide-mention--normalize-skill-path path)
                   t
                   seen-paths)
          (push skill resolved))))
    (nreverse resolved)))

(defun codex-ide-mention-input-items (prompt &optional session)
  "Return structured app-server input items for supported mentions in PROMPT.
Only `$' skill mentions produce input items today."
  (let* ((source (codex-ide-mention--source-text prompt session))
         (mentions (codex-ide-mention--collect-mentions source session))
         (skills (codex-ide-mention--available-stored-skills session)))
    (vconcat
     (delq nil
           (mapcar #'codex-ide-mention--skill-input-item
                   (codex-ide-mention--resolve-mentions
                    mentions
                    skills))))))

(defun codex-ide-mention-encode-history (prompt &optional session)
  "Encode bound mentions in PROMPT for persistent history."
  (let* ((source (codex-ide-mention--source-text prompt session))
         (mentions (seq-filter
                    (lambda (mention)
                      (eq (plist-get mention :source) 'binding))
                    (codex-ide-mention--collect-mentions source session)))
         (text (substring-no-properties source)))
    (dolist (mention (reverse mentions))
      (let ((start (plist-get mention :start))
            (end (plist-get mention :end))
            (name (plist-get mention :name))
            (path (plist-get mention :path)))
        (setq text
              (concat (substring text 0 start)
                      (format "[%s%s](%s)"
                              (plist-get mention :sigil)
                              name
                              (codex-ide-mention--history-path-encode path))
                      (substring text end)))))
    text))

(defun codex-ide-mention-decode-history (prompt &optional session)
  "Decode linked mentions in PROMPT and restore binding properties.
Only links that can be identified as encoded skill mentions are decoded.
User-authored Markdown links are preserved."
  (let ((index 0)
        (last 0)
        (out ""))
    (while (< index (length prompt))
      (let ((mention (and (eq (aref prompt index) ?\[)
                          (codex-ide-mention--parse-linked-mention-at
                           prompt
                           index))))
        (if (and mention
                 (codex-ide-mention--encoded-skill-mention-p
                  mention
                  session))
            (let* ((name (plist-get mention :name))
                   (path (plist-get mention :path))
                   (visible (concat "$" name)))
              (setq out (concat out (substring prompt last index)))
              (add-text-properties
               0
               (length visible)
               (list codex-ide-mention--binding-property
                     (list :sigil codex-ide-mention--skill-sigil
                           :kind 'skill
                           :name name
                           :path path))
               visible)
              (setq out (concat out visible)
                    index (plist-get mention :end)
                    last index))
          (setq index (1+ index)))))
    (concat out (substring prompt last))))

(defun codex-ide-mention--parse (prompt)
  "Parse PROMPT as a leading `$' skill mention.
Return nil when PROMPT does not begin with `$' after trimming outer
whitespace.  Otherwise return a plist with :name, :display, and :extra."
  (let ((text (string-trim prompt)))
    (when (string-prefix-p "$" text)
      (if (string-match "\\`\\$\\([^[:space:]]*\\)\\([[:space:]\n].*\\)?\\'" text)
          (let ((name (match-string 1 text))
                (extra (string-trim (or (match-string 2 text) ""))))
            (list :name name
                  :display (concat "$" name)
                  :extra extra))
        (list :name ""
              :display "$"
              :extra "")))))

(defun codex-ide-mention-prompt-p (prompt)
  "Return non-nil when PROMPT begins with a `$' skill marker."
  (and (codex-ide-mention--parse prompt) t))

(defun codex-ide-mention-exact-p (prompt &optional session)
  "Return non-nil when PROMPT is exactly a known `$' skill mention."
  (when-let* ((parsed (codex-ide-mention--parse prompt)))
    (let ((name (plist-get parsed :name))
          (extra (plist-get parsed :extra)))
      (and (not (string-empty-p name))
           (string-empty-p extra)
           (codex-ide-mention--skill-lookup name session)))))

(defun codex-ide-mention--input-end-position (session)
  "Return SESSION's active prompt input end position, or nil."
  (when-let* ((marker (and session
                           (codex-ide--session-metadata-get
                            session
                            :input-end-marker)))
              (buffer (and session (codex-ide-session-buffer session))))
    (when (and (buffer-live-p buffer)
               (markerp marker)
               (eq (marker-buffer marker) buffer))
      (marker-position marker))))

(defun codex-ide-mention--input-start-position (session)
  "Return SESSION's active prompt input start position, or nil."
  (when-let* ((marker (and session
                           (codex-ide-session-input-start-marker session)))
              (buffer (and session (codex-ide-session-buffer session))))
    (when (and (buffer-live-p buffer)
               (markerp marker)
               (eq (marker-buffer marker) buffer))
      (marker-position marker))))

(defun codex-ide-mention--current-input (session)
  "Return SESSION's active prompt input text, or nil."
  (when-let* ((start (codex-ide-mention--input-start-position session))
              (end (codex-ide-mention--input-end-position session))
              (buffer (and session (codex-ide-session-buffer session))))
    (when (<= start end)
      (with-current-buffer buffer
        (buffer-substring-no-properties start end)))))

(defun codex-ide-mention--mention-bounds-at-point (session)
  "Return `$' skill mention bounds at point for SESSION, or nil.
The return value is a plist with :sigil, :name-start, :name-end, and :name."
  (when-let* ((input-start (codex-ide-mention--input-start-position
                            session))
              (buffer (and session (codex-ide-session-buffer session))))
    (when (and (buffer-live-p buffer)
               (eq (current-buffer) buffer))
      (let ((pos (point))
            (input-end (or (codex-ide-mention--input-end-position
                            session)
                           (point-max))))
        (when (and (<= input-start pos)
                   (<= pos input-end))
          (let ((scan pos))
            (while (and (> scan input-start)
                        (codex-ide-mention--name-char-p
                         (char-before scan)))
              (setq scan (1- scan)))
            (when (and (> scan input-start)
                       (eq (char-before scan) ?$))
              (let ((sigil (1- scan))
                    (name-start scan)
                    (name-end pos))
                (while (and (< name-end input-end)
                            (codex-ide-mention--name-char-p
                             (char-after name-end)))
                  (setq name-end (1+ name-end)))
                (list :sigil codex-ide-mention--skill-sigil
                      :sigil-position sigil
                      :kind 'skill
                      :name-start name-start
                      :name-end name-end
                      :name (buffer-substring-no-properties
                             name-start
                             name-end))))))))))

(defun codex-ide-mention--completion-exact-at-point-p (session)
  "Return non-nil when the active `$' mention at point is a known skill."
  (when-let* ((bounds (codex-ide-mention--mention-bounds-at-point
                       session))
              (name (plist-get bounds :name)))
    (and (not (string-empty-p name))
         (codex-ide-mention--skill-lookup name session))))

(defun codex-ide-mention--apply-completion-binding (session name)
  "Record a selected skill completion NAME at point for SESSION."
  (when-let* ((bounds (codex-ide-mention--mention-bounds-at-point
                       session))
              (skill (codex-ide-mention--skill-lookup name session))
              (path (codex-ide-mention--skill-path skill)))
    (let ((sigil (plist-get bounds :sigil))
          (sigil-position (plist-get bounds :sigil-position))
          (name-start (plist-get bounds :name-start))
          (name-end (plist-get bounds :name-end)))
      (when (string= (buffer-substring-no-properties name-start name-end)
                     name)
        (add-text-properties
         sigil-position
         name-end
         (list codex-ide-mention--binding-property
               (list :sigil sigil
                     :kind 'skill
                     :name name
                     :path path)))))))

(defun codex-ide-mention--complete-at-point ()
  "Run mention completion at point."
  (completion-at-point))

(defun codex-ide-mention--completion-candidates-p (capf)
  "Return non-nil when CAPF has candidates for its current prefix."
  (let ((start (nth 0 capf))
        (end (nth 1 capf))
        (table (nth 2 capf)))
    (and start
         end
         table
         (consp
          (all-completions
           (buffer-substring-no-properties start end)
           table)))))

;;;###autoload
(defun codex-ide-mention-complete-or-newline ()
  "Complete the active mention or insert a newline.
Unlike slash commands, this never submits the prompt."
  (interactive)
  (let* ((session (codex-ide-mention--current-session))
         (capf (and session
                    (codex-ide-mention-completion-at-point session))))
    (if (and session
             capf
             (not (codex-ide-mention--completion-exact-at-point-p
                   session)))
        (codex-ide-mention--complete-at-point)
      (newline))))

(defun codex-ide-mention--completion-bounds (session)
  "Return completion bounds for SESSION's active `$' skill mention at point."
  (when-let* ((bounds (codex-ide-mention--mention-bounds-at-point
                       session)))
    (cons (plist-get bounds :name-start)
          (plist-get bounds :name-end))))

(defun codex-ide-mention-active-completion-p (&optional session)
  "Return non-nil when point is in a supported mention completion context."
  (and (codex-ide-mention-completion-at-point session) t))

(defun codex-ide-mention-completion-at-point (&optional session)
  "Return mention completion data for SESSION at point.
Only `$' skill mentions are completed today."
  (setq session (or session (codex-ide-mention--current-session)))
  (when-let* ((bounds (codex-ide-mention--completion-bounds session)))
    (let* ((table (completion-table-dynamic
                   (lambda (_)
                     (codex-ide-mention--skill-names session))))
           (capf
            (list (car bounds)
                  (cdr bounds)
                  table
                  :exclusive 'no
                  :annotation-function
                  (lambda (name)
                    (when-let* ((skill (codex-ide-mention--skill-lookup
                                        name
                                        session))
                                (description
                                 (codex-ide-mention--skill-description
                                  skill)))
                      (concat "  " description)))
                  :exit-function
                  (lambda (name status)
                    (when (memq status '(finished exact sole))
                      (codex-ide-mention--apply-completion-binding
                       session
                       name))))))
      (when (codex-ide-mention--completion-candidates-p capf)
        capf))))

(provide 'codex-ide-mention)

;;; codex-ide-mention.el ends here
