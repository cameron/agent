;;; emacs-test.el --- behavior checks for agent compose integration -*- lexical-binding: t; -*-

(require 'cl-lib)

(let* ((test-directory (file-name-directory load-file-name))
       (integration (expand-file-name "../../share/emacs/agent-compose.el"
                                      test-directory)))
  (load integration nil t))

(defun agent-compose-test-key-in-file (file expected-command)
  "Assert that M-RET in FILE resolves to EXPECTED-COMMAND."
  (with-temp-buffer
    (let ((markdown-like-map (make-sparse-keymap)))
      (define-key markdown-like-map (kbd "M-RET") #'ignore)
      (use-local-map markdown-like-map))
    (setq buffer-file-name file)
    (agent-compose-enable-for-draft)
    (unless (eq (key-binding (kbd "M-RET")) expected-command)
      (error "M-RET in %s resolves to %S, expected %S"
             file (key-binding (kbd "M-RET")) expected-command))))

(agent-compose-test-key-in-file
 "/srv/src/example/.agent-compose-send" #'agent-compose-send)
(agent-compose-test-key-in-file "/tmp/ordinary.md" #'ignore)

(defun agent-compose-test-success-clears-draft ()
  "Assert that a successful send clears both the buffer and its draft file."
  (let ((draft (make-temp-file "agent-compose-test-"))
        invocation)
    (unwind-protect
        (with-temp-buffer
          (set-visited-file-name draft)
          (insert "reply to send\n")
          (cl-letf (((symbol-function 'call-process)
                     (lambda (program _infile _destination _display &rest args)
                       (setq invocation (cons program args))
                       0)))
            (agent-compose-send))
          (unless (equal invocation (list "agent" "send" draft))
            (error "Unexpected agent invocation: %S" invocation))
          (unless (string-empty-p (buffer-string))
            (error "Successful send left text in the compose buffer"))
          (unless (zerop (file-attribute-size (file-attributes draft)))
            (error "Successful send left text in the compose draft file")))
      (delete-file draft))))

(agent-compose-test-success-clears-draft)

;;; emacs-test.el ends here
