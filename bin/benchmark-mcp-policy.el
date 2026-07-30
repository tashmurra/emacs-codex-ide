;;; benchmark-mcp-policy.el --- MCP policy gateway microbenchmark -*- lexical-binding: t; -*-

(require 'codex-ide-mcp-bridge)

(defconst codex-ide-mcp-policy-benchmark--warmups 100)
(defconst codex-ide-mcp-policy-benchmark--calls 1000)
(defconst codex-ide-mcp-policy-benchmark--maximum-added-p95-ms 1.0)

(defun codex-ide-mcp-policy-benchmark--sample
    (mode name params roots)
  "Return one MODE dispatch duration in milliseconds."
  (let ((codex-ide-mcp-bridge--dispatch-mode mode)
        (started (float-time)))
    (codex-ide-mcp-bridge--tool-call name params roots)
    (* 1000.0 (- (float-time) started))))

(defun codex-ide-mcp-policy-benchmark--p95 (samples)
  "Return the 95th percentile of SAMPLES."
  (let* ((ordered (sort samples #'<))
         (index (floor (* 0.95 (1- (length ordered))))))
    (nth index ordered)))

(let* ((root (make-temp-file "codex-ide-policy-benchmark-" t))
       (file (expand-file-name "sample.el" root))
       buffer)
  (unwind-protect
      (progn
        (write-region "(message \"benchmark\")\n" nil file nil 'silent)
        (setq buffer (find-file-noselect file))
        (let* ((name "emacs_get_buffer_info")
               (params `((buffer . ,(buffer-name buffer))))
               (roots (codex-ide-mcp-bridge--canonical-roots (list root)))
               legacy
               gateway)
          (dotimes (_ codex-ide-mcp-policy-benchmark--warmups)
            (codex-ide-mcp-policy-benchmark--sample
             'legacy name params roots)
            (codex-ide-mcp-policy-benchmark--sample
             'gateway name params roots))
          (dotimes (_ codex-ide-mcp-policy-benchmark--calls)
            (push (codex-ide-mcp-policy-benchmark--sample
                   'legacy name params roots)
                  legacy)
            (push (codex-ide-mcp-policy-benchmark--sample
                   'gateway name params roots)
                  gateway))
          (let* ((legacy-p95
                  (codex-ide-mcp-policy-benchmark--p95 legacy))
                 (gateway-p95
                  (codex-ide-mcp-policy-benchmark--p95 gateway))
                 (added-p95 (- gateway-p95 legacy-p95)))
            (princ
             (format
              "warmups=%d calls=%d legacy_p95_ms=%.4f gateway_p95_ms=%.4f added_p95_ms=%.4f limit_ms=%.1f\n"
              codex-ide-mcp-policy-benchmark--warmups
              codex-ide-mcp-policy-benchmark--calls
              legacy-p95
              gateway-p95
              added-p95
              codex-ide-mcp-policy-benchmark--maximum-added-p95-ms))
            (when (>= added-p95
                      codex-ide-mcp-policy-benchmark--maximum-added-p95-ms)
              (kill-emacs 1)))))
    (when (buffer-live-p buffer) (kill-buffer buffer))
    (delete-directory root t)))

;;; benchmark-mcp-policy.el ends here
