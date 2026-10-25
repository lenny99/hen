(load "vendors/chicken-core/chicken.condition.import.scm")
(load "vendors/chicken-core/chicken.port.import.scm")

(import scheme (chicken condition) (chicken port))

(define *tools* '())
(define *stored* "")

(define (name->string name)
  (if (symbol? name) (symbol->string name) name))

(define (register-tool! name #!key (description "") (shape '()) (handler #f))
  (set! *tools*
    (cons (vector (name->string name) description shape handler)
          *tools*)))

(define (arg alist key #!optional default)
  (let ((entry (assq key alist)))
    (if entry (cdr entry) default)))

(define (lookup-tool name)
  (let scan ((rest *tools*))
    (cond
      ((null? rest) #f)
      ((string=? name (vector-ref (car rest) 0)) (car rest))
      (else (scan (cdr rest))))))

(define (store! text)
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
      (list (vector-ref tool 0) (vector-ref tool 1) (vector-ref tool 2)))
    (reverse *tools*)))

(define (hen:tools/call! name args)
  (let ((entry (lookup-tool (name->string name))))
    (if entry
        (handle-exceptions condition
          (store! (condition-text condition))
          (store! (written ((vector-ref entry 3) args))))
        (store! (string-append "Error: unknown tool: " (name->string name))))))

(define (hen:tools/fetch)
  *stored*)
