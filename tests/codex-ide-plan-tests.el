;;; codex-ide-plan-tests.el --- Tests for structured plan updates -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for `codex-ide-plan.el'.

;;; Code:

(require 'ert)
(require 'codex-ide-plan)

(ert-deftest codex-ide-plan-normalize-update-handles-statuses-and-invalid-steps ()
  (should
   (equal
    (codex-ide-plan-normalize-update
     '((turnId . "turn-1")
       (explanation . "  Work through the checklist.  ")
       (plan . (((step . "  Finished step  ") (status . "completed"))
                ((step . "Active step") (status . "inProgress"))
                ((step . "Waiting step") (status . "pending"))
                ((step . "Unknown status") (status . "unexpected"))
                ((step . "   ") (status . "pending"))
                ((status . "pending"))))))
    '(:turn-id "turn-1"
      :explanation "Work through the checklist."
      :steps ((:step "Finished step" :status completed)
              (:step "Active step" :status in-progress)
              (:step "Waiting step" :status pending)
              (:step "Unknown status" :status pending))))))

(ert-deftest codex-ide-plan-normalize-update-accepts-vector-plans ()
  (should
   (equal
    (codex-ide-plan-normalize-update
     '((plan . [((step . "First") (status . "completed"))
                ((step . "Second") (status . "pending"))])))
    '(:turn-id nil
      :explanation nil
      :steps ((:step "First" :status completed)
              (:step "Second" :status pending))))))

(ert-deftest codex-ide-plan-normalize-update-rejects-empty-or-malformed-plans ()
  (should-not (codex-ide-plan-normalize-update nil))
  (should-not (codex-ide-plan-normalize-update '((plan . []))))
  (should-not (codex-ide-plan-normalize-update '((plan . "not-a-plan"))))
  (should-not
   (codex-ide-plan-normalize-update
    '((plan . (((step . "")) ((status . "pending"))))))))

(ert-deftest codex-ide-plan-update-signature-uses-normalized-content ()
  (let* ((list-update
          (codex-ide-plan-normalize-update
           '((turnId . "turn-1")
             (plan . (((step . "First") (status . "pending")))))))
         (vector-update
          (codex-ide-plan-normalize-update
           '((plan . [((step . "First") (status . "pending"))]))))
         (changed-update
          (codex-ide-plan-normalize-update
           '((turnId . "turn-1")
             (plan . (((step . "First") (status . "completed"))))))))
    (should (equal (codex-ide-plan-update-signature list-update)
                   (codex-ide-plan-update-signature vector-update)))
    (should-not (equal (codex-ide-plan-update-signature list-update)
                       (codex-ide-plan-update-signature changed-update)))))

(ert-deftest codex-ide-plan-format-update-renders-explanation-and-statuses ()
  (let* ((update
          '(:turn-id "turn-1"
            :explanation "A short explanation."
            :steps ((:step "Done" :status completed)
                    (:step "Working" :status in-progress)
                    (:step "Later" :status pending))))
         (formatted (codex-ide-plan-format-update update)))
    (should
     (equal (substring-no-properties formatted)
            (concat "* Updated plan\n"
                    "  └ A short explanation.\n"
                    "  ✓ Done\n"
                    "  → Working\n"
                    "  ○ Later\n\n")))
    (should (eq (get-text-property 0 'face formatted)
                'codex-ide-plan-heading-face))
    (let ((completed-position (string-match "Done" formatted))
          (active-position (string-match "Working" formatted))
          (pending-position (string-match "Later" formatted)))
      (should (eq (get-text-property completed-position 'face formatted)
                  'codex-ide-plan-completed-face))
      (should (eq (get-text-property active-position 'face formatted)
                  'codex-ide-plan-in-progress-face))
      (should (eq (get-text-property pending-position 'face formatted)
                  'codex-ide-plan-pending-face)))))

(ert-deftest codex-ide-plan-format-update-omits-empty-explanation ()
  (let ((formatted
         (codex-ide-plan-format-update
          '(:turn-id nil
            :explanation nil
            :steps ((:step "Only step" :status pending))))))
    (should
     (equal (substring-no-properties formatted)
            "* Updated plan\n  ○ Only step\n\n"))))

(provide 'codex-ide-plan-tests)

;;; codex-ide-plan-tests.el ends here
