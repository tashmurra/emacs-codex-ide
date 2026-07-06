;;; codex-ide-mention-tests.el --- Tests for codex-ide prompt mentions -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for `codex-ide-mention'.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'codex-ide)
(require 'codex-ide-mention)
(require 'codex-ide-test-fixtures)

(defun codex-ide-mention-test--skill
    (name description &optional enabled short-description)
  "Return a test skill named NAME with DESCRIPTION.
When ENABLED is nil, the skill is disabled.  SHORT-DESCRIPTION, when non-nil,
is used as the app-server interface short description."
  `((name . ,name)
    (description . ,description)
    (enabled . ,(if enabled t :json-false))
    (path . ,(format "/tmp/%s/SKILL.md" name))
    (scope . "user")
    ,@(when short-description
        `((interface . ((shortDescription . ,short-description)))))))

(defun codex-ide-mention-test--capf-candidates (capf)
  "Return all completion candidates exposed by CAPF."
  (all-completions "" (nth 2 capf)))

(defun codex-ide-mention-test--binding (name path)
  "Return a generic skill mention binding for NAME at PATH."
  (list :sigil "$"
        :kind 'skill
        :name name
        :path path))

(ert-deftest codex-ide-mention-reserves-future-provider-shape ()
  (let ((file-provider (alist-get 'file codex-ide-mention--providers))
        (directory-provider (alist-get 'directory codex-ide-mention--providers))
        (plugin-provider (alist-get 'plugin codex-ide-mention--providers)))
    (should (equal (plist-get file-provider :sigil) "@"))
    (should-not (plist-get file-provider :implemented))
    (should (equal (plist-get directory-provider :sigil) "@"))
    (should-not (plist-get directory-provider :implemented))
    (should (equal (plist-get plugin-provider :sigil) "@"))
    (should-not (plist-get plugin-provider :implemented))))

(ert-deftest codex-ide-mention-builds-skills-list-params ()
  (let ((session (make-codex-ide-session
                  :directory "/tmp/project")))
    (should (equal (codex-ide--skills-list-params session nil)
                   '((cwds . ["/tmp/project"]))))
    (should (equal (codex-ide--skills-list-params session t)
                   '((cwds . ["/tmp/project"])
                     (forceReload . t))))))

(ert-deftest codex-ide-mention-normalizes-enabled-skills ()
  (let* ((result
          `((data . (((cwd . "/tmp/project")
                      (errors . (((message . "bad skill")
                                  (path . "/tmp/bad/SKILL.md"))))
                      (skills . (,(codex-ide-mention-test--skill
                                   "imagegen"
                                   "Generate images."
                                   t)
                                 ,(codex-ide-mention-test--skill
                                   "disabled"
                                   "Disabled skill."
                                   nil))))))))
         (normalized (codex-ide-mention--normalize-skills-response result)))
    (should (equal (mapcar (lambda (skill)
                             (alist-get 'name skill))
                           (plist-get normalized :skills))
                   '("imagegen")))
    (should (= (length (plist-get normalized :errors)) 1))))

(ert-deftest codex-ide-mention-completes-skill-names-after-dollar ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq)))
    (with-temp-buffer
      (let* ((input-start (copy-marker (point)))
             (session (make-codex-ide-session
                       :buffer (current-buffer)
                       :input-start-marker input-start)))
        (codex-ide--session-metadata-put
         session
         :skills-list
         (list (codex-ide-mention-test--skill
                "imagegen"
                "Generate images."
                t)
               (codex-ide-mention-test--skill
                "skill-creator"
                "Create skills."
                t)))
        (codex-ide--session-metadata-put session :skills-list-state 'ready)
        (insert "$i")
        (let ((capf (codex-ide-mention-completion-at-point session)))
          (should capf)
          (should (= (nth 0 capf) (1+ (marker-position input-start))))
          (should (= (nth 1 capf) (point)))
          (should (equal (all-completions "i" (nth 2 capf))
                         '("imagegen"))))))))

(ert-deftest codex-ide-mention-completion-starts-at-empty-name ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq)))
    (with-temp-buffer
      (let* ((input-start (copy-marker (point)))
             (session (make-codex-ide-session
                       :buffer (current-buffer)
                       :input-start-marker input-start)))
        (codex-ide--session-metadata-put
         session
         :skills-list
         (list (codex-ide-mention-test--skill
                "imagegen"
                "Generate images."
                t)
               (codex-ide-mention-test--skill
                "skill-creator"
                "Create skills."
                t)))
        (codex-ide--session-metadata-put session :skills-list-state 'ready)
        (insert "$")
        (let ((capf (codex-ide-mention-completion-at-point session)))
          (should capf)
          (should (equal (sort (codex-ide-mention-test--capf-candidates
                                capf)
                               #'string<)
                         '("imagegen" "skill-creator"))))))))

(ert-deftest codex-ide-mention-completion-requires-matching-candidate ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq)))
    (with-temp-buffer
      (let* ((input-start (copy-marker (point)))
             (session (make-codex-ide-session
                       :buffer (current-buffer)
                       :input-start-marker input-start)))
        (codex-ide--session-metadata-put
         session
         :skills-list
         (list (codex-ide-mention-test--skill
                "imagegen"
                "Generate images."
                t)))
        (codex-ide--session-metadata-put session :skills-list-state 'ready)
        (insert "$missing")
        (should-not (codex-ide-mention-completion-at-point session))
        (should-not (codex-ide-mention-active-completion-p session))))))

(ert-deftest codex-ide-mention-annotates-skill-candidates ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq)))
    (with-temp-buffer
      (let* ((input-start (copy-marker (point)))
             (session (make-codex-ide-session
                       :buffer (current-buffer)
                       :input-start-marker input-start)))
        (codex-ide--session-metadata-put
         session
         :skills-list
         (list (codex-ide-mention-test--skill
                "imagegen"
                "Generate images."
                t
                "Images")))
        (codex-ide--session-metadata-put session :skills-list-state 'ready)
        (insert "$i")
        (let* ((capf (codex-ide-mention-completion-at-point session))
               (annotation (plist-get (nthcdr 3 capf) :annotation-function)))
          (should annotation)
          (should (equal (funcall annotation "imagegen") "  Images")))))))

(ert-deftest codex-ide-mention-completes-skill-names-mid-prompt ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq)))
    (with-temp-buffer
      (let* ((input-start (copy-marker (point)))
             (session (make-codex-ide-session
                       :buffer (current-buffer)
                       :input-start-marker input-start)))
        (codex-ide--session-metadata-put
         session
         :skills-list
         (list (codex-ide-mention-test--skill
                "imagegen"
                "Generate images."
                t)))
        (codex-ide--session-metadata-put session :skills-list-state 'ready)
        (insert "hello $i")
        (let ((capf (codex-ide-mention-completion-at-point session)))
          (should capf)
          (should (= (nth 0 capf)
                     (+ (marker-position input-start) (length "hello $"))))
          (should (= (nth 1 capf) (point)))
          (should (equal (all-completions "i" (nth 2 capf))
                         '("imagegen"))))))))

(ert-deftest codex-ide-mention-exact-p-requires-known-skill-without-extra-text ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session)))
    (codex-ide--session-metadata-put
     session
     :skills-list
     (list (codex-ide-mention-test--skill
            "imagegen"
            "Generate images."
            t)))
    (codex-ide--session-metadata-put session :skills-list-state 'ready)
    (should (codex-ide-mention-exact-p "$imagegen" session))
    (should (codex-ide-mention-exact-p " $imagegen " session))
    (should-not (codex-ide-mention-exact-p "$missing" session))
    (should-not (codex-ide-mention-exact-p "$imagegen make a logo" session))
    (should-not (codex-ide-mention-exact-p "use $imagegen" session))))

(ert-deftest codex-ide-mention-complete-or-newline-does-not-submit ()
  (codex-ide-test-with-fixture temporary-file-directory
			       (with-temp-buffer
				 (codex-ide-session-mode)
				 (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
				       (session (make-codex-ide-session
						 :buffer (current-buffer)
						 :directory default-directory
						 :thread-id "thread-1"
						 :status "idle"))
				       submitted)
				   (setq-local codex-ide--session session)
				   (codex-ide--session-metadata-put
				    session
				    :skills-list
				    (list (codex-ide-mention-test--skill
					   "imagegen"
					   "Generate images."
					   t)))
				   (codex-ide--session-metadata-put session :skills-list-state 'ready)
				   (codex-ide--insert-input-prompt session "$imagegen")
				   (goto-char (codex-ide--input-end-position session))
				   (cl-letf (((symbol-function 'codex-ide-submit)
					      (lambda ()
						(interactive)
						(setq submitted t))))
				     (codex-ide-mention-complete-or-newline))
				   (should-not submitted)
				   (should (equal (codex-ide-mention--current-input session)
						  "$imagegen\n"))))))

(ert-deftest codex-ide-mention-complete-or-newline-inserts-newline-without-matches ()
  (codex-ide-test-with-fixture temporary-file-directory
			       (with-temp-buffer
				 (codex-ide-session-mode)
				 (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
				       (session (make-codex-ide-session
						 :buffer (current-buffer)
						 :directory default-directory
						 :thread-id "thread-1"
						 :status "idle"))
				       completed)
				   (setq-local codex-ide--session session)
				   (codex-ide--session-metadata-put
				    session
				    :skills-list
				    (list (codex-ide-mention-test--skill
					   "imagegen"
					   "Generate images."
					   t)))
				   (codex-ide--session-metadata-put session :skills-list-state 'ready)
				   (codex-ide--insert-input-prompt session "Please check $foo")
				   (goto-char (codex-ide--input-end-position session))
				   (cl-letf (((symbol-function 'codex-ide-mention--complete-at-point)
					      (lambda ()
						(setq completed t))))
				     (codex-ide-mention-complete-or-newline))
				   (should-not completed)
				   (should (equal (codex-ide-mention--current-input session)
						  "Please check $foo\n"))))))

(ert-deftest codex-ide-mention-builds-skill-input-items ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session)))
    (codex-ide--session-metadata-put
     session
     :skills-list
     (list (codex-ide-mention-test--skill
            "imagegen"
            "Generate images."
            t)
           (codex-ide-mention-test--skill
            "skill-creator"
            "Create skills."
            t)
           (codex-ide-mention-test--skill
            "disabled"
            "Disabled skill."
            nil)))
    (codex-ide--session-metadata-put session :skills-list-state 'ready)
    (let ((items (append (codex-ide-mention-input-items
                          "Use $imagegen, $skill-creator, $PATH, and $disabled."
                          session)
                         nil)))
      (should (equal (mapcar (lambda (item)
                               (alist-get 'name item))
                             items)
                     '("imagegen" "skill-creator")))
      (should (equal (mapcar (lambda (item)
                               (alist-get 'type item))
                             items)
                     '("skill" "skill"))))))

(ert-deftest codex-ide-mention-input-items-does-not-refresh-cold-cache ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session))
        refreshed)
    (cl-letf (((symbol-function 'codex-ide-mention-refresh-skill-cache)
               (lambda (&rest _)
                 (setq refreshed t))))
      (should-not (append (codex-ide-mention-input-items
                           "$imagegen"
                           session)
                          nil))
      (should-not refreshed))))

(ert-deftest codex-ide-mention-bound-skill-input-item-survives-cold-cache ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session))
        (prompt "$foo"))
    (add-text-properties
     0
     (length prompt)
     (list codex-ide-mention--binding-property
           (codex-ide-mention-test--binding
            "foo"
            "skill:///tmp/foo/SKILL.md"))
     prompt)
    (let ((items (append (codex-ide-mention-input-items
                          prompt
                          session)
                         nil)))
      (should (= (length items) 1))
      (should (equal (alist-get 'type (car items)) "skill"))
      (should (equal (alist-get 'name (car items)) "foo"))
      (should (equal (alist-get 'path (car items))
                     "skill:///tmp/foo/SKILL.md")))))

(ert-deftest codex-ide-mention-linked-skill-input-item-requires-cache-by-default ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session)))
    (should-not (append (codex-ide-mention-input-items
                         "Use [$foo](skill:///tmp/foo)."
                         session)
                        nil))))

(ert-deftest codex-ide-mention-linked-skill-input-item-allows-uncached-path-when-enabled ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (codex-ide-mention-allow-uncached-skill-paths t)
        (session (make-codex-ide-session)))
    (let ((items (append (codex-ide-mention-input-items
                          "Use [$foo](skill:///tmp/foo)."
                          session)
                         nil)))
      (should (= (length items) 1))
      (should (equal (alist-get 'type (car items)) "skill"))
      (should (equal (alist-get 'name (car items)) "foo"))
      (should (equal (alist-get 'path (car items))
                     "skill:///tmp/foo")))))

(ert-deftest codex-ide-mention-ordinary-markdown-links-do-not-create-skill-items ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session)))
    (codex-ide--session-metadata-put
     session
     :skills-list
     (list (codex-ide-mention-test--skill
            "price"
            "A skill with the same visible label."
            t)))
    (codex-ide--session-metadata-put session :skills-list-state 'ready)
    (dolist (prompt '("See [$price](docs.md)."
                      "See [$price](https://example.com)."))
      (should-not (append (codex-ide-mention-input-items
                           prompt
                           session)
                          nil)))))

(ert-deftest codex-ide-mention-history-skill-path-requires-cache-by-default ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session)))
    (let* ((decoded (codex-ide-mention-decode-history
                     "Use [$foo](/tmp/foo/SKILL.md)."
                     session))
           (items (append (codex-ide-mention-input-items
                           decoded
                           session)
                          nil)))
      (should (equal (substring-no-properties decoded)
                     "Use [$foo](/tmp/foo/SKILL.md)."))
      (should-not
       (cl-loop for index below (length decoded)
                thereis (get-text-property
                         index
                         codex-ide-mention--binding-property
                         decoded)))
      (should-not items))))

(ert-deftest codex-ide-mention-history-skill-path-allows-uncached-path-when-enabled ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (codex-ide-mention-allow-uncached-skill-paths t)
        (session (make-codex-ide-session)))
    (let* ((decoded (codex-ide-mention-decode-history
                     "Use [$foo](skill:///tmp/foo)."
                     session))
           (items (append (codex-ide-mention-input-items
                           decoded
                           session)
                          nil)))
      (should (equal (substring-no-properties decoded) "Use $foo."))
      (should (= (length items) 1))
      (should (equal (alist-get 'name (car items)) "foo"))
      (should (equal (alist-get 'path (car items))
                     "skill:///tmp/foo")))))

(ert-deftest codex-ide-mention-deduplicates-skill-input-items ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session)))
    (codex-ide--session-metadata-put
     session
     :skills-list
     (list (codex-ide-mention-test--skill
            "imagegen"
            "Generate images."
            t)))
    (codex-ide--session-metadata-put session :skills-list-state 'ready)
    (let ((items (append (codex-ide-mention-input-items
                          "$imagegen then $imagegen"
                          session)
                         nil)))
      (should (= (length items) 1))
      (should (equal (alist-get 'name (car items)) "imagegen")))))

(ert-deftest codex-ide-mention-linked-mention-resolves-by-path ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session)))
    (codex-ide--session-metadata-put
     session
     :skills-list
     (list (codex-ide-mention-test--skill
            "imagegen"
            "Generate images."
            t)
           (codex-ide-mention-test--skill
            "other"
            "Other skill."
            t)))
    (codex-ide--session-metadata-put session :skills-list-state 'ready)
    (let* ((path (alist-get
                  'path
                  (codex-ide-mention--skill-lookup "other" session)))
           (items (append (codex-ide-mention-input-items
                           (format "Use [$not-the-name](%s)" path)
                           session)
                          nil)))
      (should (= (length items) 1))
      (should (equal (alist-get 'name (car items)) "other")))))

(ert-deftest codex-ide-mention-linked-mention-overrides-env-var-filter ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session)))
    (codex-ide--session-metadata-put
     session
     :skills-list
     '(((name . "PATH")
        (description . "Env-like skill.")
        (enabled . t)
        (path . "/tmp/PATH/SKILL.md")
        (scope . "user"))))
    (codex-ide--session-metadata-put session :skills-list-state 'ready)
    (let ((items (append (codex-ide-mention-input-items
                          "Use [$PATH](/tmp/PATH/SKILL.md)."
                          session)
                         nil)))
      (should (= (length items) 1))
      (should (equal (alist-get 'name (car items)) "PATH")))))

(ert-deftest codex-ide-mention-binding-overrides-name-fallback ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session)))
    (codex-ide--session-metadata-put
     session
     :skills-list
     (list (codex-ide-mention-test--skill
            "same"
            "First same-name skill."
            t)
           '((name . "same")
             (description . "Second same-name skill.")
             (enabled . t)
             (path . "/tmp/same-second/SKILL.md")
             (scope . "user"))))
    (codex-ide--session-metadata-put session :skills-list-state 'ready)
    (let ((prompt "$same"))
      (add-text-properties
       0
       (length prompt)
       (list codex-ide-mention--binding-property
             (codex-ide-mention-test--binding
              "same"
              "/tmp/same-second/SKILL.md"))
       prompt)
      (let ((items (append (codex-ide-mention-input-items
                            prompt
                            session)
                           nil)))
        (should (= (length items) 1))
        (should (equal (alist-get 'path (car items))
                       "/tmp/same-second/SKILL.md"))))))

(ert-deftest codex-ide-mention-binding-overrides-env-var-filter ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session)))
    (codex-ide--session-metadata-put
     session
     :skills-list
     '(((name . "PATH")
        (description . "Env-like skill.")
        (enabled . t)
        (path . "/tmp/PATH/SKILL.md")
        (scope . "user"))))
    (codex-ide--session-metadata-put session :skills-list-state 'ready)
    (let ((prompt "$PATH"))
      (add-text-properties
       0
       (length prompt)
       (list codex-ide-mention--binding-property
             (codex-ide-mention-test--binding
              "PATH"
              "/tmp/PATH/SKILL.md"))
       prompt)
      (let ((items (append (codex-ide-mention-input-items
                            prompt
                            session)
                           nil)))
        (should (= (length items) 1))
        (should (equal (alist-get 'name (car items)) "PATH"))
        (should (equal (codex-ide-mention-encode-history prompt)
                       "[$PATH](/tmp/PATH/SKILL.md)"))))))

(ert-deftest codex-ide-mention-edited-binding-falls-back-to-visible-name ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session)))
    (codex-ide--session-metadata-put
     session
     :skills-list
     (list (codex-ide-mention-test--skill
            "imagegen"
            "Generate images."
            t)
           (codex-ide-mention-test--skill
            "other"
            "Other skill."
            t)))
    (codex-ide--session-metadata-put session :skills-list-state 'ready)
    (let ((prompt "$other"))
      (add-text-properties
       0
       (length prompt)
       (list codex-ide-mention--binding-property
             (codex-ide-mention-test--binding
              "imagegen"
              "/tmp/imagegen/SKILL.md"))
       prompt)
      (let ((items (append (codex-ide-mention-input-items
                            prompt
                            session)
                           nil)))
        (should (= (length items) 1))
        (should (equal (alist-get 'name (car items)) "other"))))))

(ert-deftest codex-ide-mention-encodes-and-decodes-history-mentions ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session))
        (prompt "$imagegen now"))
    (codex-ide--session-metadata-put
     session
     :skills-list
     '(((name . "imagegen")
        (description . "Generate images.")
        (enabled . t)
        (path . "/tmp/imagegen/SKILL.md")
        (scope . "user"))))
    (codex-ide--session-metadata-put session :skills-list-state 'ready)
    (add-text-properties
     0
     (length "$imagegen")
     (list codex-ide-mention--binding-property
           (codex-ide-mention-test--binding
            "imagegen"
            "/tmp/imagegen/SKILL.md"))
     prompt)
    (let* ((encoded (codex-ide-mention-encode-history prompt))
           (decoded (codex-ide-mention-decode-history encoded session))
           (binding (get-text-property
                     0
                     codex-ide-mention--binding-property
                     decoded)))
      (should (equal encoded "[$imagegen](/tmp/imagegen/SKILL.md) now"))
      (should (equal (substring-no-properties decoded) "$imagegen now"))
      (should (equal (plist-get binding :sigil) "$"))
      (should (eq (plist-get binding :kind) 'skill))
      (should (equal (plist-get binding :name) "imagegen"))
      (should (equal (plist-get binding :path)
                     "/tmp/imagegen/SKILL.md")))))

(ert-deftest codex-ide-mention-history-escapes-skill-path-target ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session))
        (prompt "$foo now")
        (path "/tmp/foo)bar%baz/SKILL.md"))
    (codex-ide--session-metadata-put
     session
     :skills-list
     `(((name . "foo")
        (description . "Foo skill.")
        (enabled . t)
        (path . ,path)
        (scope . "user"))))
    (codex-ide--session-metadata-put session :skills-list-state 'ready)
    (add-text-properties
     0
     (length "$foo")
     (list codex-ide-mention--binding-property
           (codex-ide-mention-test--binding "foo" path))
     prompt)
    (let* ((encoded (codex-ide-mention-encode-history prompt))
           (decoded (codex-ide-mention-decode-history encoded session))
           (binding (get-text-property
                     0
                     codex-ide-mention--binding-property
                     decoded)))
      (should (equal encoded "[$foo](/tmp/foo%29bar%25baz/SKILL.md) now"))
      (should (equal (substring-no-properties decoded) "$foo now"))
      (should (equal (plist-get binding :path) path)))))

(ert-deftest codex-ide-mention-decode-history-preserves-user-markdown-link ()
  (let* ((prompt "See [$price](docs.md) for details.")
         (decoded (codex-ide-mention-decode-history prompt)))
    (should (equal (substring-no-properties decoded) prompt))
    (should-not
     (cl-loop for index below (length decoded)
              thereis (get-text-property
                       index
                       codex-ide-mention--binding-property
                       decoded)))))

(ert-deftest codex-ide-mention-decode-history-decodes-known-skill-path ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session)))
    (codex-ide--session-metadata-put
     session
     :skills-list
     '(((name . "imagegen")
        (description . "Generate images.")
        (enabled . t)
        (path . "/virtual/imagegen")
        (scope . "user"))))
    (codex-ide--session-metadata-put session :skills-list-state 'ready)
    (let* ((decoded (codex-ide-mention-decode-history
                     "[$imagegen](/virtual/imagegen) now"
                     session))
           (binding (get-text-property
                     0
                     codex-ide-mention--binding-property
                     decoded)))
      (should (equal (substring-no-properties decoded) "$imagegen now"))
      (should (equal (plist-get binding :path) "/virtual/imagegen")))))

(ert-deftest codex-ide-mention-refresh-skill-cache-stores-async-result ()
  (let ((codex-ide--session-metadata (make-hash-table :test 'eq))
        (session (make-codex-ide-session
                  :directory "/tmp/project"
                  :process 'process))
        force-reload-seen)
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (_process) t))
              ((symbol-function 'codex-ide-log-message)
               (lambda (&rest _) nil))
              ((symbol-function 'codex-ide--list-skills-async)
               (lambda (_session force-reload callback)
                 (setq force-reload-seen force-reload)
                 (funcall callback
                          `((data . (((cwd . "/tmp/project")
                                      (errors . nil)
                                      (skills . (,(codex-ide-mention-test--skill
                                                   "imagegen"
                                                   "Generate images."
                                                   t)))))))
                          nil))))
      (codex-ide-mention-refresh-skill-cache session t))
    (should force-reload-seen)
    (should (equal (codex-ide-mention--skill-names session) '("imagegen")))))

(ert-deftest codex-ide-initialize-session-warms-mention-cache ()
  (let ((project-dir (codex-ide-test--make-temp-project))
        warmed)
    (codex-ide-test-with-fixture project-dir
				 (codex-ide-test-with-fake-processes
				  (let ((session (codex-ide--create-process-session)))
				    (cl-letf (((symbol-function 'codex-ide--request-sync)
					       (lambda (_session method _params)
						 (should (equal method "initialize"))
						 '((ok . t))))
					      ((symbol-function 'codex-ide-mention-refresh-skill-cache)
					       (lambda (target-session &optional force-reload)
						 (setq warmed (list target-session force-reload)))))
				      (codex-ide--initialize-session session)
				      (should (equal warmed (list session nil)))))))))

(ert-deftest codex-ide-skills-changed-refreshes-mention-cache ()
  (codex-ide-test-with-fixture temporary-file-directory
			       (with-temp-buffer
				 (let ((session (make-codex-ide-session
						 :buffer (current-buffer)
						 :directory default-directory
						 :thread-id "thread-1"
						 :status "idle"))
				       refreshed)
				   (setq-local codex-ide--session session)
				   (cl-letf (((symbol-function 'codex-ide-log-message)
					      (lambda (&rest _) nil))
					     ((symbol-function
					       'codex-ide-mention-refresh-skill-cache-after-change)
					      (lambda (target-session)
						(setq refreshed target-session))))
				     (codex-ide--handle-notification
				      session
				      '((method . "skills/changed")
					(params . nil))))
				   (should (eq refreshed session))))))

(provide 'codex-ide-mention-tests)

;;; codex-ide-mention-tests.el ends here
