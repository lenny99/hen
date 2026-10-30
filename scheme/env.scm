(load "vendors/chicken-core/chicken.condition.import.scm")
(load "vendors/chicken-core/chicken.port.import.scm")

(module hen (hen:eval!
             hen:tools/list
             hen:tools/call!
             hen:tools/fetch
             register-module!
             register-tool!
             arg
             config
             env
             name->string
             hen:config/set!
             hen:assert!
             hen:registrations/checkpoint!
             hen:registrations/undo!)
  (import scheme (chicken module) (chicken condition)
          (chicken port) (chicken base))

  (reexport (only (chicken base) include include-relative))

  (define (tool-entry published summary when description shape handler)
    (vector published summary when description shape handler))

  (define (tool-published entry) (vector-ref entry 0))
  (define (tool-summary entry) (vector-ref entry 1))
  (define (tool-when entry) (vector-ref entry 2))
  (define (tool-description entry) (vector-ref entry 3))
  (define (tool-shape entry) (vector-ref entry 4))
  (define (tool-handler entry) (vector-ref entry 5))

  (define *tools* '())
  (define *modules* '())
  (define *current-module* #f)
  (define *journal* '())
  (define *config-values* '())
  (define *config-decls* '())

  (define *stored* "")
  (define *stored-fresh* #f)

  (define (name->string name)
    (if (symbol? name) (symbol->string name) name))

  (define (arg alist key #!optional default)
    (let ((entry (assq key alist)))
      (if entry (cdr entry) default)))

  (define (env var)
    (list 'env (name->string var)))

  (define (source-descriptor? thing)
    (and (pair? thing)
         (eq? (car thing) 'env)
         (pair? (cdr thing))
         (null? (cddr thing))
         (string? (cadr thing))))

  (define (descriptor-list thing)
    (cond
      ((not (pair? thing))
       (error "invalid configuration sources" thing))
      (else
       (if (source-descriptor? thing)
           (list thing)
           thing))))

  (define (resolve-config descriptor)
    (let ((var (cadr descriptor)))
      (cond
        ((assoc var *config-values* string=?) =>
         (lambda (entry) (cdr entry)))
        (else #f))))

  (define (config name #!key (sources #f) (secret #f))
    (let* ((declared
            (if (pair? sources)
                (descriptor-list sources)
                (error "no configuration sources declared" (name->string name))))
           (decl (vector (name->string name) declared secret))
           (resolved #f))
      (set! *config-decls* (cons decl *config-decls*))
      (set! *journal* (cons (list 'decl decl) *journal*))
      (let scan ((rest declared))
        (cond
          ((null? rest)
           (error "missing configuration value for declared name"
                  (name->string name)))
          ((not (source-descriptor? (car rest)))
           (error "invalid configuration source for declared name"
                  (car rest)
                  (name->string name)))
          (else
           (and-let* ((value (resolve-config (car rest))))
             (set! resolved value)
             (if (null? (cdr rest))
                 'done
                 (scan (cdr rest))))
           (unless resolved (scan (cdr rest))))))
      resolved))

  (define (hen:config/set! var value)
    (set! *config-values*
      (cons (cons (name->string var) value) *config-values*)))

  (define (published-name-char-ok? char)
    (or (char<=? #\a char #\z)
        (char<=? #\A char #\Z)
        (char<=? #\0 char #\9)
        (char=? char #\_)
        (char=? char #\.)
        (char=? char #\-)))

  (define (published-name-ok? name)
    (let loop ((index 0))
      (cond
        ((>= index (string-length name)) #t)
        ((published-name-char-ok? (string-ref name index))
         (loop (+ index 1)))
        (else #f))))

  (define (check-published-name name)
    (unless (> (string-length name) 0)
      (error "published tool name is empty"))
    (unless (<= (string-length name) 64)
      (error "published tool name is longer than 64 characters" name))
    (unless (published-name-ok? name)
      (error "published tool name contains characters outside [A-Za-z0-9_.-]"
             name)))

  (define (register-module! module-name #!key (summary ""))
    (unless (or (symbol? module-name) (string? module-name))
      (error "module name must be a symbol or a string" module-name))
    (let ((name (if (symbol? module-name) module-name (string->symbol module-name))))
      (when (eq? name 'hen)
        (error "module name 'hen' is reserved for the built-in module" name))
      (when (assq name *modules*)
        (error "module is already registered" name))
      (set! *current-module* name)
      (set! *modules*
        (cons (list name (name->string summary) '()) *modules*))
      (set! *journal* (cons (list 'module name) *journal*))))

  (define (duplicate-short-entry? short)
    (and-let* ((record *current-module*)
               (record (assq record *modules*))
               ((member short (caddr record) string=?)))
      #t))

  (define (remember-short! short)
    (and-let* ((record *current-module*)
               (record (assq record *modules*)))
      (set-car! (cddr record) (cons short (caddr record)))))

  (define (forget-short! name short)
    (and-let* ((record (assq name *modules*)))
      (set-car! (cddr record)
                (filter-list
                 (lambda (entry) (not (string=? entry short)))
                 (caddr record)))))

  (define (filter-list ok? things)
    (cond ((null? things) '())
          ((ok? (car things))
           (cons (car things) (filter-list ok? (cdr things))))
          (else (filter-list ok? (cdr things)))))

  (define (register-tool! short-name
                          #!key
                          (summary "")
                          (when "")
                          (description "")
                          (shape '())
                          (handler #f))
    (unless (or (symbol? short-name) (string? short-name))
      (error "tool name must be a symbol or a string" short-name))
    (let* ((short (name->string short-name))
           (module *current-module*)
           (published
            (if module
                (string-append (name->string module) "-" short)
                short)))
      (check-published-name published)
      (if module
          (if (duplicate-short-entry? short)
              (error "tool short name is registered twice in module"
                     (name->string module)
                     short)
              (remember-short! short))
          'toplevel-registration)
      (set! *tools*
        (cons (tool-entry published summary when description shape handler)
              *tools*))
      (set! *journal*
        (cons (list 'tool published short module) *journal*))))

  (define (hen:registrations/checkpoint!)
    (set! *journal* (cons (list 'checkpoint *current-module*) *journal*)))

  (define (revert-event entry)
    (case (car entry)
      ((tool)
       (let ((published (cadr entry))
             (short (caddr entry))
             (module (cadddr entry)))
         (set! *tools* (remove-tool published))
         (when module (forget-short! module short))))
      ((module)
       (let ((name (cadr entry)))
         (set! *modules*
           (filter-list
            (lambda (record) (not (eq? (car record) name)))
            *modules*))
         (when (and *current-module* (eq? *current-module* name))
           (set! *current-module* #f))))
      ((decl)
       (set! *config-decls*
         (filter-list
          (lambda (record) (not (eq? record (cadr entry))))
          *config-decls*)))
      (else (error "unknown registration-journal event" entry))))

  (define (remove-tool published)
    (filter-list
     (lambda (entry) (not (string=? (tool-published entry) published)))
     *tools*))

  (define (hen:registrations/undo!)
    (let loop ((rest *journal*))
      (cond
        ((null? rest)
         (set! *journal* '())
         (set! *tools* '())
         (set! *modules* '())
         (set! *current-module* #f)
         (set! *config-decls* '()))
        ((eq? (caar rest) 'checkpoint)
         (set! *journal* rest)
         (set! *current-module* (cadr (car rest)))
         'done)
        (else
         (revert-event (car rest))
         (loop (cdr rest))))))

  (define (hen:assert! value expected)
    (let ((actual (written value))
          (wanted (written expected)))
      (if (string=? actual wanted)
          #t
          (error "assertion failed: expected " wanted ", got " actual))))

  (define (lookup-tool name)
    (let scan ((rest *tools*))
      (cond
        ((null? rest) #f)
        ((string=? name (tool-published (car rest))) (car rest))
        (else (scan (cdr rest))))))

  (define (store! text)
    (set! *stored-fresh* #t)
    (set! *stored* text)
    (string-length text))

  (define (written value)
    (if (string? value)
        value
        (with-output-to-string (lambda () (write value)))))

  (define (trim-newline text)
    (let* ((n (string-length text))
           (start (if (and (> n 0) (char=? (string-ref text 0) #\newline)) 1 0))
           (end (if (and (> n start) (char=? (string-ref text (- n 1)) #\newline))
                    (- n 1)
                    n)))
      (substring text start end)))

  (define (condition-text condition)
    (trim-newline
      (with-output-to-string
        (lambda () (print-error-message condition)))))

  (define (hen:tools/list)
    (map
      (lambda (tool)
        (list (tool-published tool)
              (tool-summary tool)
              (tool-when tool)
              (tool-description tool)
              (tool-shape tool)))
      (reverse *tools*)))

  (define (hen:tools/call! name args)
    (let ((entry (lookup-tool (name->string name))))
      (if entry
          (handle-exceptions condition
            (store! (condition-text condition))
            (store! (written ((tool-handler entry) args))))
          (store! (string-append "Error: unknown tool: " (name->string name))))))

  (define (trailing-input? port)
    (let loop ()
      (let ((char (read-char port)))
        (cond
          ((eof-object? char) #f)
          ((char-whitespace? char) (loop))
          (else #t)))))

  (define (hen:eval! source)
    (set! *stored-fresh* #f)
    (handle-exceptions condition
      (store! (condition-text condition))
      (with-input-from-string source
        (lambda ()
          (let ((word (read)))
            (cond
              ((eof-object? word) (store! "Error: no expression"))
              ((trailing-input? (current-input-port))
               (store! "Error: trailing input after the expression"))
              (else
               (let ((value (eval word)))
                 (if *stored-fresh*
                     (string-length *stored*)
                     (store! (written value)))))))))))

  (define (hen:tools/fetch)
    *stored*))

(module hen-plugin (register-module!
                    register-tool!
                    config
                    arg
                    env
                    name->string
                    include
                    include-relative)
  (import hen (chicken module) (chicken base))
  (reexport (only hen register-module! register-tool! config arg env name->string))
  (reexport (only (chicken base) include include-relative)))

(import hen)

(import (chicken condition) (chicken port))
