;;; rustic-babel.el --- Org babel facilities for rustic -*-lexical-binding: t-*-

;;; Commentary:

;; Async org-babel execution using cargo. Building and running is seperated
;; into two processes, as it's easier to get the output for the result of the
;; current source block.

;;; Code:

(require 'org)
(require 'ob)
(require 'ob-eval)
(require 'ob-ref)
(require 'ob-core)

(add-to-list 'org-babel-tangle-lang-exts '("rust" . "rs"))

(defcustom rustic-babel-display-compilation-buffer nil
  "Whether to display compilation buffer."
  :type 'boolean
  :group 'rustic-mode)

(defcustom rustic-babel-format-src-block t
  "Whether to format a src block automatically after successful execution."
  :type 'boolean
  :group 'rustic-mode)

(defvar rustic-babel-buffer-name '((:default . "*rust-babel*")))

(defvar rustic-babel-process-name "rustic-babel-process"
  "Process name for org-babel rust compilation processes.")

(defvar rustic-babel-compilation-buffer "*rustic-babel-compilation-buffer*"
  "Buffer name for org-babel rust compilation process buffers.")

(defvar rustic-babel-dir nil
  "Holds the latest rust babel project directory.")

(defvar rustic-babel-src-location nil
  "Marker, holding location of last evaluated src block.")

(defvar rustic-babel-params nil
  "Babel parameters.")

(defun rustic-babel-eval (dir)
  "Start a rust babel compilation process in directory DIR."
  (let* ((err-buff (get-buffer-create rustic-babel-compilation-buffer))
         (default-directory dir)
         (coding-system-for-read 'binary)
         (process-environment (nconc
	                           (list (format "TERM=%s" "ansi"))
                               process-environment))
         (params '("cargo" "build"))
         (inhibit-read-only t))
    (with-current-buffer err-buff
      (erase-buffer)
      (setq-local default-directory dir)
      (rustic-compilation-mode))
    (if rustic-babel-display-compilation-buffer
        (display-buffer err-buff))
     (make-process
                 :name rustic-babel-process-name
                 :buffer err-buff
                 :command params
                 :filter #'rustic-compile-filter
                 :sentinel #'rustic-babel-sentinel)))

(defun rustic-babel-sentinel (proc string)
  "Sentinel for rust babel compilation processes."
  (let ((proc-buffer (process-buffer proc))
        (inhibit-read-only t))
    (if (zerop (process-exit-status proc))
        (let* ((default-directory rustic-babel-dir) 
               (result (shell-command-to-string "cargo run --quiet"))
               (result-params (list (cdr (assq :results rustic-babel-params))))
               (params rustic-babel-params)
               (marker rustic-babel-src-location))
          (unless rustic-babel-display-compilation-buffer
            (kill-buffer proc-buffer))
          (with-current-buffer (marker-buffer marker)
            (goto-char marker)
            (org-babel-remove-result rustic-info)
            (org-babel-insert-result result result-params rustic-info)
            (if rustic-babel-format-src-block
                (let ((full-body (org-element-property :value (org-element-at-point)))
                      (proc (make-process :name "rustic-babel-format"
                                          :buffer "rustic-babel-format-buffer"
                                          :command `(,rustic-rustfmt-bin)
                                          :filter #'rustic-compile-filter
                                          :sentinel #'rustic-babel-format-sentinel)))
                  (while (not (process-live-p proc))
                    (sleep-for 0.01))
                  (process-send-string proc full-body)
                  (process-send-eof proc)))))
      (pop-to-buffer proc-buffer))))

(defun rustic-babel-format-sentinel (proc output)
  (let ((proc-buffer (process-buffer proc))
        (marker rustic-babel-src-location))
    (save-excursion
      (with-current-buffer proc-buffer
        (when (string-match-p "^finished" output)
          (with-current-buffer (marker-buffer marker)
            (goto-char marker)
            (org-babel-update-block-body
             (with-current-buffer "rustic-babel-format-buffer"
               (buffer-string)))))))
    (kill-buffer "rustic-babel-format-buffer")))

(defun rustic-babel-generate-project ()
  "Create rust project in `org-babel-temporary-directory'."
  (let* ((default-directory org-babel-temporary-directory)
         (dir (make-temp-file-internal "cargo" 0 "" nil)))
    (shell-command-to-string (format "cargo new %s --bin --quiet" dir))
    (setq rustic-babel-dir (expand-file-name dir))))

(defun rustic-babel-cargo-toml (dir params)
  "Append crates to Cargo.toml."
  (let ((crates (cdr (assq :crates params)))
        (toml (expand-file-name "Cargo.toml" dir))
        (str ""))
    (dolist (crate crates)
      (setq str (concat str (car crate) " = " "\"" (cdr crate) "\"" "\n")))
    (write-region str nil toml t)))

(defun org-babel-execute:rust (body params)
  "Execute a block of Rust code with Babel."
  (rustic-process-live rustic-babel-process-name)
  (let* ((dir (rustic-babel-generate-project))
         (project (car (reverse (split-string rustic-babel-dir "\\/"))))
         (main (expand-file-name "main.rs" (concat dir "/src"))))
    (setq rustic-info (org-babel-get-src-block-info))
    (rustic-babel-cargo-toml dir params)
    (setq rustic-babel-params params)
    (let ((default-directory dir))
      (write-region (concat "#![allow(non_snake_case)]\n" body) nil main nil 0)
      (rustic-babel-eval dir)
      (setq rustic-babel-src-location (set-marker (make-marker) (point) (current-buffer)))
      project)))

(provide 'rustic-babel)
;;; rustic-babel.el ends here