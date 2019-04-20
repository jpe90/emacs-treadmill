;;; treadmill.el --- Development environment for Gerbil Scheme -*- lexical-binding: t -*-

;; Copyright © 2018-9 Thunk NYC Corp.
;;
;; Author: Edwin Watkeys <edw@poseur.com>
;;
;; URL: https://github.com/thunknyc/emacs-treadmill
;; Keywords: languages gerbil scheme lisp
;; Version: 0.1-snapshot
;; Package-Requires: ((emacs "25.1") (company "0.9.0") (cl-lib "0.3"))

;;; Commentary:

;; Provides an interaction buffer and a minor-mode for Gerbil Scheme
;; code.

;; Start a Gerbil network REPL and connect:
;; M-x treadmill-spawn

;; Connect to an existing Gerbil network REPL:
;; M-x treadmill-connect

;;; License:

;; Copyright © 2018-9 Thunk NYC Corp.

;; Permission is hereby granted, free of charge, to any person
;; obtaining a copy of this software and associated documentation
;; files (the "Software"), to deal in the Software without
;; restriction, including without limitation the rights to use, copy,
;; modify, merge, publish, distribute, sublicense, and/or sell copies
;; of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be
;; included in all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
;; BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
;; ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
;; CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Code:

(require 'subr-x)


(defvar treadmill-interpreter-name nil
  "Explicit location of the Gerbil interpreter.")

(defconst treadmill-default-host "127.0.0.1"
  "Default host for network REPL connection.")

(defvar treadmill-current-interaction-buffer nil
  "The interaction buffer in which expressions are evaluated.")

;; Public

(defvar-local treadmill-interaction-buffer nil
  "The interaction buffer associate with a particular Gerbil
  source buffer.")

(defvar-local treadmill-current-module nil
  "Current module of an interaction or Gerbil source.")

(defvar-local treadmill-ia-mark nil
  "The minimum editable mark in an interaction buffer.")

;;; Private

(defvar-local treadmill--spawn-port nil
  "The REPL to connect to as reported by the Gerbil interpreter.")

(defvar-local treadmill--spawn-process nil
  "The REPL-spawning process, if any, associated with a REPL
  connection.")

(defvar-local treadmill--repl-awaiting-value nil
  "Indicates whether a synchronous REPL evaluation is awaiting a
  value.")

(defvar-local treadmill--repl-process nil
  "The REPL process associated with an interaction buffer.")

;;;###autoload
(defun treadmill-plugin-null-hook (event arg)
  "The no-op plugin handler.

Handle filter or notification EVENT and ARG in the event that
your handler does not."
  (cond ((eq event 'command) arg)
        ((eq event 'init-forms) arg)
        ((eq event 'keymap) arg)
        ((eq event 'expression) arg)
        ((eq event 'gerbil-keymap) arg)
        ((eq event 'connected) nil)
        ((eq event 'quitting) nil)
        (t
         (warn "Unimplemented event `%s' in `treadmill-plugin-null-hook`"
               event))))

;;;###autoload
(defvar treadmill-plugin-functions nil
  "Abnormal hook for reigstering plugin functions.")

(defun treadmill--plugin-fold (event arg)
  "Send EVENT and filter ARG through each plugin."
  (let ((hooks treadmill-plugin-functions)
        (arg arg))
    (while hooks
      (let ((proc (car hooks)))
        (let ((new-arg (funcall proc event arg)))
          (setq arg new-arg))
        (setq hooks (cdr hooks))))
    arg))

(defun treadmill--plugin-hook (event arg)
  "Notify reigstered hook functions that EVENT(ARG) occurred."
  (run-hook-with-args 'treadmill-plugin-functions event arg))

(defun treadmill--find-pkg (dir)
  "Find and parse a package file in DIR.

Given a directory name DIR, load and parse the package file
there.  Return the package name inside the file or nil if file
doesn't exist or doesn't have a `package:' entry."
  (let ((pkg-file (format "%s/gerbil.pkg" dir)))
    (when (file-readable-p pkg-file)
        (let ((b (generate-new-buffer "*treadmill-find-pkg*")))
          (with-current-buffer b
            (insert-file-contents pkg-file)
            (let* ((txt (buffer-substring (point-min) (point-max)))
                   (alist (read (format "(%s)" txt))))
              (kill-buffer)
              (symbol-name (car (alist-get 'package: alist)))))))))

(defun treadmill--build-module-name (els fdir)
  "Build a module name through recursive descent of the filesystem.
Recursively descend FDIR, accummulating found module path
elements in ELS, and return a full-qualified module name string
if a package file is found."
  (if (string-empty-p fdir) nil
    (if-let ((pkg (treadmill--find-pkg fdir)))
        (string-join (cons pkg els) "/")
        (let ((el (file-name-nondirectory fdir)))
          (treadmill--build-module-name
           (cons el els)
           (substring (file-name-directory fdir) 0 -1))))))

(defun treadmill-gerbil-current-module ()
  "Return the module associated with the Gerbil buffer."
  (cond ((bound-and-true-p treadmill-current-module)
         treadmill-current-module)
        ((not (buffer-file-name))
         (warn "No module name for Gerbil unsaved buffer")
         treadmill-current-module)
        (t (let* ((fname (buffer-file-name))
                  (module-leaf (file-name-sans-extension
                                (file-name-nondirectory fname)))
                  (fdir (substring (file-name-directory fname) 0 -1)))
             (if-let ((module (treadmill--build-module-name
                               (list module-leaf) fdir)))
                 (progn (setq treadmill-current-module module)
                        module)
               (warn "No package file name for Gerbil source"))))))

(defun treadmill--gxi-location ()
  "Return location of `gxi' command, the Gerbil interpreter.

Consult environment for Gerbil location or, if defined return
TREADMILL-INTERPRETER-NAME."
  (let ((gerbil-home (getenv "GERBIL_HOME")))
    (cond ((and (bound-and-true-p treadmill-interpreter-name)
                (not (string-empty-p treadmill-interpreter-name)))
           treadmill-interpreter-name)
          (gerbil-home
           (format "%s/bin/gxi" gerbil-home))
          (t nil))))

;;;###autoload
(defun treadmill-spawn ()
  "Start a local Gerbil network REPL and connect to it."
  (interactive)
  (treadmill--start-server))

(defun treadmill--command ()
  "Return the command to execute when spawning Gerbil interpreter."
  (list (treadmill--gxi-location)
        "-e" "(import :thunknyc/treadmill)"
        "-e" "(start-treadmill!)"))

(defun treadmill--extract-result ()
  "If the process buffer does contain a result, return it."
  (goto-char (point-min))
  (let ((bom (search-forward-regexp "^\\(> \\)\\{0,1\\}|\\([-0-9a-fA-F]\\{36\\}\\)>>" 42 t)))
    (when bom
      (goto-char (max (- (point-max) 48) 1))
      (let* ((sentinel (match-string 2))
             (eom-pat (format "<<%s|[\r\n]+[0-9]*> " sentinel))
             (eom (search-forward-regexp eom-pat nil t)))
        (when eom
          (buffer-substring-no-properties 40 (match-beginning 0)))))))

(defun treadmill--repl-completion-filter (proc)
  "Construct a process filter that will call PROC when a result is ready."
  (lambda (p s)
    ;; Boilerplate
    (when (buffer-live-p (process-buffer p))
      (with-current-buffer (process-buffer p)
        (let ((moving (= (point) (process-mark p))))
          (save-excursion
            ;; Insert the text, advancing the process marker.
            (goto-char (process-mark p))
            (insert s)
            (set-marker (process-mark p) (point)))
          (if moving (goto-char (process-mark p))))))
    ;; Not boilerplate
    (with-current-buffer (process-buffer p)
      (when-let ((result (treadmill--extract-result)))
        (funcall proc (read result))))))

(defun treadmill--spawn-filter (p s)
  "Gerbil interpreter spawn filter function.

Determine when process P has, by delivering string S provided the
output from the Gerbil interpreter which tells us which port to
connect to."
  ;; Boilerplate
  (when (buffer-live-p (process-buffer p))
    (with-current-buffer (process-buffer p)
      (let ((moving (= (point) (process-mark p))))
        (save-excursion
          ;; Insert the text, advancing the process marker.
          (goto-char (process-mark p))
          (insert s)
          (set-marker (process-mark p) (point)))
        (if moving (goto-char (process-mark p))))))
  ;; Not boilerplate
  (with-current-buffer (process-buffer p)
    (when (null treadmill--spawn-port)
      (save-excursion
        (goto-char 0)
        (when (search-forward-regexp
               "Running network REPL on port \\([0-9]+\\)."
               nil t)
          (let ((port (string-to-number (match-string 1))))
            (setq treadmill--spawn-port port)
            (message "Network REPL starting on port %d" port)
            (treadmill-connect "127.0.0.1" port)))))))

(defun treadmill--secure-transcript ()
  "Mark past interactions as read-only.
The compexity of the procedure is related to properly managing
the stickiness of the front and back of the
content."
  (let ((saved-inhibit-read-only inhibit-read-only))
    (setq inhibit-read-only t)
    (add-text-properties (point-min) (point-max)
                         '(front-sticky t rear-nonsticky t read-only t))
    (setq inhibit-read-only saved-inhibit-read-only)))

(defmacro treadmill--inserting (&rest exprs)
  "Evaluate EXPRS with INHIBIT-READ-ONLY true."
  (let ((result (make-symbol "result")))
    `(progn
       (setq inhibit-read-only t)
       (let ((,result (progn ,@exprs)))
         (setq inhibit-read-only nil)
         ,result))))

(defun treadmill--insert (what)
  "Insert WHAT into interaction buffer using INHIBIT-READ-ONLY."
  (let ((saved-inhibit-read-only inhibit-read-only))
    (setq inhibit-read-only t)
    (insert what)
    (setq inhibit-read-only saved-inhibit-read-only)))

(defmacro treadmill--propertizing (properties &rest exprs)
  "Propertize all text inserted into buffer.

Applies PROPERTIES to all text between the value of POINT before
EXPRS are evaluated and the value of POINT afterwards."
  (let ((beg (make-symbol "beg"))
        (result (make-symbol "result")))
    `(let ((,beg (point))
           (,result (progn ,@exprs)))
       (add-text-properties ,beg (point) ,properties)
       ,result)))

(defun treadmill-ia-propertized-message (properties msg &rest args)
  "Issue MSG with ARGS in the interaction buffer with PROPERTIES."
  (treadmill--with-connection
   (with-current-buffer treadmill-interaction-buffer
     (save-excursion
      (goto-char treadmill-ia-mark)
      (beginning-of-line)
      (treadmill--inserting
       (treadmill--propertizing
        properties
        (insert ";; ")
        (insert (apply #'message msg args))
        (insert "\n")))))))

(defun treadmill-ia-message (msg &rest args)
  "Issue message MSG format string and ARGS to interaction buffer.

Also issue a conventional message."
  (apply #'treadmill-ia-propertized-message
         '(face font-lock-comment-face)
         msg
         args)
  (apply #'message msg args))

(defun treadmill-ia-warn (msg &rest args)
  "Issue MSG format string and ARGS to interaction buffer as a warning.

Also issue a conventional warning."
  (apply #'treadmill-ia-propertized-message
         '(face font-lock-warning-face)
         msg
         args)
  (apply #'warn msg args))

(defun treadmill-issue-prompt ()
  "Issue a fresh prompt.  Useful if Treadmill gets confused."
  (interactive)
  (goto-char (point-max))
  (treadmill--inserting
   (treadmill--propertizing '(face font-lock-builtin-face)
    (insert (format "%s> " (or treadmill-current-module "TOP")))))
  (setq treadmill-ia-mark (point-max-marker))
  (treadmill--secure-transcript))

(defun treadmill--normalize-module-string (module)
  "Return a string representation of MODULE.

Returned string is suitable for display in the interaction
prompt."
  (cond ((equal module "TOP") -1)
        ((string-empty-p module) -1)
        (t module)))

(defun treadmill-gerbil-enter-module (module)
  "Use MODULE when evaluating the current buffer."
  (interactive "sEnter module: (\"\" for TOP): ")
  (setq treadmill-current-module (treadmill--normalize-module-string module)))

(defun treadmill-ia-enter-module (module)
  "Use MODULE when evaluated expressions."
  (interactive "sEnter module: (\"\" for TOP): ")
  (setq treadmill-current-module (treadmill--normalize-module-string module))
  (let ((unsent-input (buffer-substring-no-properties
                       treadmill-ia-mark (point-max))))
    (goto-char (point-max))
    (insert "\n")
    (treadmill-issue-prompt)
    (insert unsent-input)))

(defun treadmill--insert-result (result)
  "Insert RESULT into interaction buffer."
  (let ((values (car result))
        (stdout (cadr result))
        (stderr (caddr result)))
    (treadmill--propertizing
     '(face font-lock-keyword-face)
     (insert (string-join (mapcar (lambda (v) (format "%s" v)) values) "\n")))
    (if (string-empty-p stdout) ""
      (progn
        (treadmill--propertizing
         '(face font-lock-comment-face)
         (insert (format "\n```stdout\n")))
        (treadmill--propertizing
         '(face font-lock-string-face)
         (insert (format "%s\n" stdout)))
        (treadmill--propertizing
         '(face font-lock-comment-face)
         (insert (format "```")))))
    '(face font-lock-warning-face)
    (if (string-empty-p stderr) ""
      (progn
        (treadmill--propertizing
         '(face font-lock-comment-face)
         (insert (format "\n```stderr\n")))
        (treadmill--propertizing
         '(face font-lock-warning-face)
         (insert (format "%s\n" stderr)))
        (treadmill--propertizing
         '(face font-lock-comment-face)
         (insert (format "```")))))
    (if values (insert "\n"))))

(defvar-local treadmill--eval-cancelled nil)

(defun treadmill-ia-eval-cancel ()
  "Cancel on ongoing interactive evaluation."
  (interactive)
  (cond ((not treadmill--repl-awaiting-value)
         (message "No ongoing evaluation"))
        (t
         (process-send-string
          treadmill--repl-process
          (unibyte-string #xff #xf4 #x04))
         (setq treadmill--repl-awaiting-value nil)
         (setq treadmill--eval-cancelled t)
         (treadmill--propertizing '(face font-lock-warning-face)
                                  (treadmill--insert "cancelled\n"))
         (setq treadmill--repl-awaiting-value nil)
         (treadmill-issue-prompt))))

(defun treadmill-ia-eval ()
  "Evaluate the expression(s) in the current input."
  (interactive)
  (let ((s (buffer-substring-no-properties treadmill-ia-mark (point-max)))
        (stdin "")
        (b (current-buffer)))
    (goto-char (point-max))
    (treadmill--insert "\n")
    (let ((feedback-point (point)))
      (treadmill--propertizing '(face font-lock-comment-face)
                               (treadmill--insert ";;; Evaluating..."))
      (setq treadmill--repl-awaiting-value t)
      (setq treadmill--eval-cancelled nil)
      (treadmill-eval-io-async
       (treadmill--plugin-fold 'expression s)
       stdin
       treadmill-current-module
       (lambda (result)
         (with-current-buffer b
           (setq treadmill--repl-awaiting-value nil)
           (delete-region feedback-point (point-max))
           (goto-char (point-max))
           (treadmill--inserting (treadmill--insert-result result))
           (treadmill-issue-prompt)
           (goto-char (point-max))))))))

;;;###autoload
(defun treadmill-connect (host port)
  "Connect to a Gerbil network REPL already running on HOST at PORT."
  (interactive
   "sConnect to network REPL at host: \nsREPL port on %s: \n")
  (let* ((repl-b (generate-new-buffer "*treadmill-repl*"))
         (repl-p (open-network-stream "treadmill-repl"
                                      repl-b host port)))
    ;; If treadmill--spawn-process is defined it means we're in the
    ;; spawn buffer and we should connect the spawn buffer with the
    ;; repl buffer, so we can tear down the spawn process when we kill
    ;; the repl.
    (let ((spawn-process treadmill--spawn-process))
      (when spawn-process
        (setq treadmill--repl-process repl-p)
        (with-current-buffer repl-b
          (setq treadmill--spawn-process spawn-process))))
    (message "Connected to network REPL on port %d" port)
    (let ((b (generate-new-buffer "*treadmill*")))
      (setq treadmill-current-interaction-buffer (buffer-name b))
      (with-current-buffer repl-b
        (setq treadmill-interaction-buffer b)
              (setq treadmill--repl-process repl-p))
      (switch-to-buffer b)
      (setq treadmill--repl-process repl-p)
      (treadmill--propertizing '(face font-lock-comment-face)
       (insert ";;; Welcome to the Gerbil Treadmill\n"))
      (treadmill-issue-prompt)
      (treadmill-mode)
      (treadmill--plugin-hook 'connected b))))

(defun treadmill--start-server ()
  "Create process to spawn a network REPL and connect to it."
  (let* ((b (generate-new-buffer "*treadmill-spawn*"))
         (p (make-process :name "treadmill-spawn"
                          :buffer b :coding 'utf-8
                          :type 'pipe
                          :command (treadmill--plugin-fold
                                    'command
                                    (treadmill--command))
                          :filter 'treadmill--spawn-filter)))
    (with-current-buffer b
      (setq treadmill--spawn-process p)
      (let ((forms (treadmill--plugin-fold 'init-forms "")))
        (when (not (string-empty-p forms))
          (process-send-string p forms)
          (process-send-string p "\n"))))))

(defun treadmill-eval1-async (s completion)
  "Evaluate S in network REPL and invoke COMPLETION when done."
  (let ((p treadmill--repl-process))
    (with-current-buffer (process-buffer p)
      (erase-buffer)
      (setq treadmill--repl-awaiting-value t)
      (set-process-filter
       p (treadmill--repl-completion-filter completion))
      (process-send-string p (format "(eval/sentinel %s)\n" s)))))

(defmacro treadmill--with-connection (&rest exprs)
  "Evalutate EXPRS in context where network REPL process is accessible."
  (let ((temp-b (make-symbol "buffer")))
    `(if (bound-and-true-p treadmill--repl-process)
         (progn ,@exprs)
       (let ((,temp-b
              (and treadmill-current-interaction-buffer
                   (get-buffer treadmill-current-interaction-buffer))))
         (with-current-buffer ,temp-b ,@exprs)))))

(defvar-local treadmill--eval-value nil
  "Value of last blocking network REPL evaluation.")

(defun treadmill-eval1 (s)
  "Evaluate single expression S in network REPL.

Evaluate S synchronously (i.e. by blocking) without exception
protection and return the value.  The S parameter should be
an expression that returns a value (not e.g. `(define foo 42)` as
a no-value result hangs this procedure."
  (treadmill--with-connection
   (setq treadmill--repl-awaiting-value t)
     (let ((b (current-buffer)))
       (treadmill-eval1-async
        s
        (lambda (val)
          (with-current-buffer b
            (setq treadmill--repl-value val)
            (setq treadmill--repl-awaiting-value nil)))))
     (while treadmill--repl-awaiting-value
       (sleep-for 0 50))
     treadmill--eval-value))

(defun treadmill--module-string (mod)
  "Return module string for MOD suitable for use by evaluation procedures."
  (cond ((eq mod -1) "#f")
        ((null mod) "#f")
        (t (format "'%s" mod))))

(defun treadmill-eval-io-async (expr-string input-string module completion)
  "Evaluate EXPR-STRING with INPUT-STRING as standard input.

In the context of MODULE, evaluate EXPR-STRING in the network
REPL, providing INPUT-STRING as input via a string input port.
When complete, invoke COMPLETION with the results of the
evaluation."
  (treadmill--with-connection
   (let ((p treadmill--repl-process))
     (with-current-buffer (process-buffer p)
       (erase-buffer)
       (setq treadmill--repl-awaiting-value t)
       (set-process-filter p (treadmill--repl-completion-filter completion))
       (let ((s (format "(eval/sentinel (eval-string/input-string %S %S %s))\n"
                        expr-string input-string
                        (treadmill--module-string module))))
         (process-send-string p s))))))

(defun treadmill--repl-quit ()
  "Tear down processes and delete buffers associated with the network REPL."
  (let* ((repl-p treadmill--repl-process)
         (repl-b (current-buffer))
         (spawn-p (buffer-local-value 'treadmill--spawn-process repl-b))
         (spawn-b (if spawn-p (process-buffer spawn-p) nil)))
    (delete-process repl-p)
    (kill-buffer repl-b)
    (when spawn-p
      (delete-process spawn-p)
      (kill-buffer spawn-b))))

(defun treadmill-ia-quit ()
  "Shut down Treadmill.

Delete the current Treadmill interaction buffer and all related
buffers and processes."
  (interactive)
  (treadmill--plugin-hook 'quitting (current-buffer))
  (with-current-buffer (process-buffer treadmill--repl-process)
    (treadmill--repl-quit))
  (kill-buffer))

(defun treadmill-gerbil-send-region (start end &optional arg)
  "Evaluate the current region.

Evaluate the expression(s) between START and END.  If ARG is
non-nil, insert the resulting values after point.  Otherwise
display the resulting values in the message area."
  (interactive "r")
  (let ((sexp (buffer-substring-no-properties start end))
        (g-b (current-buffer)))
    (if-let ((ia-b (and treadmill-current-interaction-buffer
                        (get-buffer treadmill-current-interaction-buffer))))
        (let ((module (treadmill-gerbil-current-module)))
          (with-current-buffer ia-b
            (treadmill-eval-io-async
             sexp "" module
             (lambda (val)
               (if arg
                   (with-current-buffer g-b
                     (insert
                      (string-join
                       (mapcar (lambda (v) (format "%s" v)) (car val))
                       " ")))
                 (if-let ((stderr (caddr val))
                          (stderr-present (not (string-empty-p stderr))))
                     (message "Error: %s" stderr)
                   (message "%s"
                            (string-join (mapcar (lambda (v)
                                                   (format "=> %s" v))
                                                 (car val))
                                         "\n"))))))))
      (error "Treadmill: No current interaction buffer"))))

(defun treadmill-gerbil-eval-last (arg)
  "Evaluate the expression before POINT.

If ARG is non-nil, insert the resulting value(s) at POINT,
otherwise display the results in the message area."
  (interactive "P")
  (treadmill-gerbil-send-region
   (save-excursion (backward-sexp) (point))
   (point)
   arg))

(defun treadmill-gerbil-eval-toplevel ()
  "Evaluate the current expression under or before POINT."
  (interactive)
  (save-excursion
   (end-of-defun)
   (let ((end (point)))
     (beginning-of-defun)
     (treadmill-gerbil-send-region (point) end nil))))

(defvar-local treadmill--switch-last-buffer nil
  "Name of Gerbil buffer that most recently switched to interaction buffer.")

(defun treadmill-ia-switch ()
  "Switch to the most recent Gerbil buffer."
  (interactive)
  (if treadmill--switch-last-buffer
      (switch-to-buffer treadmill--switch-last-buffer)
    (error "No most recent Gerbil buffer")))

(defun treadmill-gerbil-switch ()
  "Switch to the current Treadmill interaction buffer."
  (interactive)
  (let ((b (current-buffer)))
    (switch-to-buffer (get-buffer treadmill-current-interaction-buffer))
    (setq treadmill--switch-last-buffer b)))

(defun treadmill-move-beginning-of-line (n-lines)
  "Move to the beginning of current line.

If N-LINES is 1 and the current line contains the interaction
prompt and POINT is after it, move POINT to the first editable
position.  Otherwise, function just as MOVE-BEGINNING-OF-LINE."
  (interactive "^p")
  (cond ((and (eq n-lines 1) (> (point) treadmill-ia-mark))
         (goto-char treadmill-ia-mark))
        (t (move-beginning-of-line n-lines))))

;;;###autoload
(defvar treadmill-mode-hook nil
  "Hook for executing code after Treadmill starts.")

(defun treadmill--make-mode-map ()
  "Construct Treadmill mode map, including plugins' bindings."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'treadmill-ia-eval)
    (define-key map (kbd "C-c C-z") 'treadmill-ia-switch)
    (define-key map (kbd "C-c C-m") 'treadmill-ia-enter-module)
    (define-key map (kbd "C-c C-q") 'treadmill-ia-quit)
    (define-key map (kbd "C-a") 'treadmill-move-beginning-of-line)
    (define-key map (kbd "C-c C-c") 'treadmill-ia-eval-cancel)
    (treadmill--plugin-fold 'keymap map)))

;;;###autoload
(defun treadmill-mode ()
  "Major mode for interacting with Gerbil."
  (interactive)
  (use-local-map (treadmill--make-mode-map))
  (setq mode-name "Treadmill Interaction")
  (setq major-mode 'treadmill-mode)
  (company-mode t)
  (make-local-variable 'after-change-functions)
  (run-hooks 'treadmill-mode-hook))

(defun treadmill-gerbil-refresh-module ()
  "Reload if current buffer has a non-toplevel module associated with it."
  (interactive)
  (let ((mod (treadmill-gerbil-current-module)))
    (cond ((eq mod -1) (message "Cannot reload a toplevel buffer"))
          ((null mod) (message "No current module"))
          (t
           (message "Reloading %s" mod)
           (treadmill-eval-io-async
            (format "(reload! :%s)" mod) "" "thunknyc/treadmill"
            (lambda (val)
              (let ((stderr (caddr val)))
                (if (string-empty-p stderr)
                    (treadmill-ia-message "Module %s reloaded" mod)
                  (treadmill-ia-warn "Error while reloading module %s: %s"
                                     mod (string-trim stderr))))))))))

(defun treadmill-gerbil-import-module ()
  "Import module associated with current buffer."
  (interactive)
  (let ((mod (treadmill-gerbil-current-module)))
    (cond ((eq mod -1) (message "Cannot import a toplevel buffer"))
          ((null mod) (message "No current module"))
          (t
           (message "Importing %s" mod)
           (treadmill-eval-io-async
            (format "(import :%s)" mod) ""
            (treadmill--with-connection treadmill-current-module)
            (lambda (val)
              (let ((stderr (caddr val)))
                (if (string-empty-p stderr)
                    (treadmill-ia-message "Module %s imported" mod)

                  (treadmill-ia-warn "Error while importing module %s: %s"
                        mod (string-trim stderr))))))))))

;;;###autoload
(define-minor-mode treadmill-gerbil-mode
  "Mode for talking to Treadmill in Gerbil buffers."
  :lighter " TM"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") 'treadmill-gerbil-send-region)
            (define-key map (kbd "C-c C-e") 'treadmill-gerbil-eval-toplevel)
            (define-key map (kbd "C-x C-e") 'treadmill-gerbil-eval-last)
            (define-key map (kbd "C-c C-z") 'treadmill-gerbil-switch)
            (define-key map (kbd "C-c TAB") 'treadmill-gerbil-import-module)
            (define-key map (kbd "C-c C-r") 'treadmill-gerbil-refresh-module)
            (define-key map (kbd "C-M-x") 'treadmill-gerbil-eval-toplevel)
            (define-key map (kbd "C-c m") 'treadmill-gerbil-enter-module)
            (treadmill--plugin-fold 'gerbil-keymap map))
  (company-mode t))

(require 'treadmill-complete)
(require 'treadmill-history)

(provide 'treadmill)

;;; treadmill.el ends here
