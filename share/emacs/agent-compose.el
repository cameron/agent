;;; agent-compose.el --- send a compose-pane draft to the agent pane -*- lexical-binding: t; -*-

;; Editor side of the agent compose pane. `agent-compose-send' saves the
;; draft, delivers the text below the last --- marker through `agent send',
;; and on success clears the draft buffer. This file ships with the agent
;; package so it always matches the installed `agent send'.
;; M-Enter is active only in agent compose drafts. See the COMPOSE PANE
;; section of agent(lab-reference).

(defun agent-compose-send ()
  "Save the draft, send below the last --- marker, then clear the buffer."
  (interactive)
  (save-buffer)
  (with-current-buffer (get-buffer-create "*agent-send*") (erase-buffer))
  (if (zerop (call-process "agent" nil "*agent-send*" nil
                           "send" (buffer-file-name)))
      (progn
        (erase-buffer)
        (save-buffer))
    (display-buffer "*agent-send*")))

(defvar agent-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-RET") #'agent-compose-send)
    map)
  "Keymap active in agent compose draft buffers.")

(define-minor-mode agent-compose-mode
  "Send an agent compose draft with `M-RET'."
  :lighter " AgentCompose"
  :keymap agent-compose-mode-map)

(defun agent-compose-enable-for-draft ()
  "Enable `agent-compose-mode' in an agent compose draft buffer."
  (when (and buffer-file-name
             (string= (file-name-nondirectory buffer-file-name)
                      ".agent-compose-send"))
    (agent-compose-mode 1)))

(add-hook 'find-file-hook #'agent-compose-enable-for-draft)

(provide 'agent-compose)
;;; agent-compose.el ends here
