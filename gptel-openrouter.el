;;; gptel-openrouter.el --- OpenRouter model catalog for gptel -*- lexical-binding: t; -*-

;;; Commentary:

;; Populate gptel OpenRouter backends from OpenRouter's model API.  The
;; catalog is cached locally and refreshed asynchronously, so model
;; selection never waits for the network.  Model capabilities, context
;; windows, pricing, and knowledge cutoffs are exposed to gptel.
;;
;;   (require 'gptel-openrouter)
;;   (setq gptel-backend
;;         (gptel-openrouter-make-backend "OpenRouter"
;;           :key (getenv "OPENROUTER_API_KEY")
;;           :stream t))
;;   (gptel-openrouter-auto-refresh-mode 1)

;;; Code:

(require 'cl-lib)
(require 'gptel)
(require 'gptel-openai)
(require 'json)
(require 'seq)
(require 'url)

(defgroup gptel-openrouter nil
  "OpenRouter model catalog support for gptel."
  :group 'gptel)

(defcustom gptel-openrouter-models-url
  "https://openrouter.ai/api/v1/models?output_modalities=text"
  "URL from which to retrieve OpenRouter's text-output models."
  :type 'string)

(defcustom gptel-openrouter-cache-file
  (expand-file-name "gptel-openrouter/models.json" user-emacs-directory)
  "File in which to cache OpenRouter's model catalog."
  :type 'file)

(defcustom gptel-openrouter-refresh-interval (* 24 60 60)
  "Seconds between OpenRouter model catalog refreshes."
  :type 'integer)

(defcustom gptel-openrouter-fallback-models '(openrouter/auto)
  "Models available before the first catalog download succeeds."
  :type '(repeat sexp))

(defcustom gptel-openrouter-mime-types
  '((image . ("image/png" "image/jpeg" "image/webp" "image/gif"))
    (file . ("application/pdf"))
    (audio . ("audio/wav" "audio/mpeg" "audio/mp3" "audio/aiff"
              "audio/aac" "audio/ogg" "audio/flac" "audio/mp4"))
    (video . ("video/mp4" "video/mpeg" "video/mov" "video/webm")))
  "MIME types accepted by OpenRouter's multimodal API."
  :type 'sexp)

(defvar gptel-openrouter-model-specs nil
  "Current OpenRouter model specifications in gptel format.")
(defvar gptel-openrouter--backends nil)
(defvar gptel-openrouter--refresh-timer nil)
(defvar gptel-openrouter--refreshing nil)

(defun gptel-openrouter--model-spec (model)
  "Convert an OpenRouter API MODEL plist to a gptel model spec."
  (let* ((id (plist-get model :id))
         (architecture (plist-get model :architecture))
         (inputs (plist-get architecture :input_modalities))
         (outputs (plist-get architecture :output_modalities))
         (parameters (plist-get model :supported_parameters))
         (pricing (plist-get model :pricing))
         (modalities '(image file audio video))
         capabilities mime-types)
    (dolist (modality modalities)
      (when (member (symbol-name modality) inputs)
        (push modality capabilities)
        (setq mime-types
              (append mime-types
                      (alist-get modality gptel-openrouter-mime-types)))))
    (when capabilities (push 'media capabilities))
    (when (member "tools" parameters) (push 'tool-use capabilities))
    (when (or (member "response_format" parameters)
              (member "structured_outputs" parameters))
      (push 'json capabilities))
    (when (or (plist-member model :reasoning)
              (seq-some (lambda (parameter)
                          (member parameter '("reasoning" "reasoning_effort"
                                              "include_reasoning")))
                        parameters))
      (push 'reasoning capabilities))
    (when (or (plist-member pricing :input_cache_read)
              (plist-member pricing :input_cache_write))
      (push 'cache capabilities))
    (when (member "image" inputs) (push 'url capabilities))
    `(,(intern id)
      :description ,(plist-get model :description)
      :capabilities ,(nreverse capabilities)
      :input-modalities ,inputs
      :output-modalities ,outputs
      :mime-types ,mime-types
      :context-window ,(when-let* ((context (plist-get model :context_length)))
                         (/ context 1000.0))
      :input-cost ,(* 1000000
                      (string-to-number (or (plist-get pricing :prompt) "0")))
      :output-cost ,(* 1000000
                       (string-to-number
                        (or (plist-get pricing :completion) "0")))
      :cutoff-date ,(plist-get model :knowledge_cutoff))))

(defun gptel-openrouter--read-response-buffer ()
  "Read an OpenRouter models response from the current buffer."
  (let* ((response (json-parse-buffer :object-type 'plist
                                      :array-type 'list
                                      :null-object nil :false-object nil))
         (models (plist-get response :data)))
    (unless (and (listp models)
                 (seq-every-p (lambda (model)
                                (stringp (plist-get model :id)))
                              models))
      (error "Invalid OpenRouter models response"))
    (mapcar #'gptel-openrouter--model-spec models)))

(defun gptel-openrouter--read-cache ()
  "Read and convert the cached OpenRouter model catalog."
  (when (file-readable-p gptel-openrouter-cache-file)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents gptel-openrouter-cache-file)
          (gptel-openrouter--read-response-buffer))
      (error
       (message "Could not read OpenRouter model cache: %s"
                (error-message-string err))
       nil))))

(defun gptel-openrouter--models ()
  "Return cached OpenRouter model specs or fallback models."
  (or gptel-openrouter-model-specs
      (setq gptel-openrouter-model-specs
            (or (gptel-openrouter--read-cache)
                gptel-openrouter-fallback-models))))

(defun gptel-openrouter--install-models (model-specs)
  "Install MODEL-SPECS into every backend made by this package."
  (setq gptel-openrouter-model-specs model-specs)
  (let ((models (gptel--process-models model-specs)))
    (dolist (backend gptel-openrouter--backends)
      (setf (gptel-backend-models backend) models))))

(defun gptel-openrouter--refresh-callback (status quiet)
  "Handle an OpenRouter response with URL STATUS.
Do not report success when QUIET is non-nil."
  (unwind-protect
      (condition-case err
          (progn
            (when-let* ((failure (plist-get status :error)))
              (error "Network error: %s" failure))
            (goto-char (point-min))
            (unless (re-search-forward "\r?\n\r?\n" nil t)
              (error "Malformed HTTP response"))
            (let* ((body-start (point))
                   (model-specs (gptel-openrouter--read-response-buffer))
                   (cache-dir (file-name-directory
                               gptel-openrouter-cache-file)))
              (make-directory cache-dir t)
              (let ((temp-file
                     (make-temp-file (expand-file-name ".models-" cache-dir))))
                (unwind-protect
                    (progn
                      (write-region body-start (point-max) temp-file nil 'silent)
                      (rename-file temp-file gptel-openrouter-cache-file t))
                  (when (file-exists-p temp-file) (delete-file temp-file))))
              (gptel-openrouter--install-models model-specs)
              (unless quiet
                (message "Updated %d OpenRouter models"
                         (length model-specs)))))
        (error
         (message "Could not update OpenRouter models: %s"
                  (error-message-string err))))
    (setq gptel-openrouter--refreshing nil)
    (kill-buffer (current-buffer))))

;;;###autoload
(defun gptel-openrouter-refresh-models (&optional quiet)
  "Asynchronously refresh OpenRouter models and their metadata.
With optional QUIET, suppress the success message."
  (interactive)
  (unless gptel-openrouter--refreshing
    (setq gptel-openrouter--refreshing t)
    (condition-case err
        (url-retrieve gptel-openrouter-models-url
                      #'gptel-openrouter--refresh-callback
                      (list quiet) 'silent 'inhibit-cookies)
      (error
       (setq gptel-openrouter--refreshing nil)
       (message "Could not start OpenRouter model update: %s"
                (error-message-string err))))))

(defun gptel-openrouter--cache-stale-p ()
  "Return non-nil if the OpenRouter model cache needs refreshing."
  (or (not (file-exists-p gptel-openrouter-cache-file))
      (> (- (float-time)
            (float-time (file-attribute-modification-time
                         (file-attributes gptel-openrouter-cache-file))))
         gptel-openrouter-refresh-interval)))

;;;###autoload
(define-minor-mode gptel-openrouter-auto-refresh-mode
  "Refresh the OpenRouter model catalog periodically."
  :global t
  :group 'gptel-openrouter
  (when (timerp gptel-openrouter--refresh-timer)
    (cancel-timer gptel-openrouter--refresh-timer))
  (setq gptel-openrouter--refresh-timer nil)
  (when gptel-openrouter-auto-refresh-mode
    (setq gptel-openrouter--refresh-timer
          (run-at-time (if (gptel-openrouter--cache-stale-p)
                           2 gptel-openrouter-refresh-interval)
                       gptel-openrouter-refresh-interval
                       #'gptel-openrouter-refresh-models 'quiet))))

;;;###autoload
(defun gptel-openrouter-make-backend (name &rest args)
  "Register an OpenRouter gptel backend named NAME.
ARGS are keyword arguments accepted by `gptel-make-openai', such as
`:key', `:stream', and `:request-params'.  The host, endpoint, and
models are supplied by this package."
  (declare (indent 1))
  (let ((backend
         (apply #'gptel-make-openai name
                :host "openrouter.ai"
                :endpoint "/api/v1/chat/completions"
                :models (gptel-openrouter--models)
                args)))
    (cl-pushnew backend gptel-openrouter--backends :test #'eq)
    backend))

(provide 'gptel-openrouter)
;;; gptel-openrouter.el ends here
