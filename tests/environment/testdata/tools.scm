(register-tool! 'hen-echo
  #:description "Echoes its text argument back."
  #:shape '(type object
            (properties (text (type string)
                              (description "text to echo")))
            (required text))
  #:handler (lambda (args) (arg args 'text)))

(register-tool! 'hen-boom
  #:description "Always raises."
  #:shape '(type object)
  #:handler (lambda (args) (error "boom")))

(register-tool! 'hen-keys
  #:description "Joins its arg keys with spaces."
  #:shape '(type object)
  #:handler (lambda (args)
             (let loop ((rest (map (lambda (entry) (name->string (car entry))) args))
                        (out "") (first #t))
               (cond ((null? rest) out)
                     (first (loop (cdr rest) (car rest) #f))
                     (else (loop (cdr rest) (string-append out " " (car rest)) #f))))))

(define *ticks* 0)

(register-tool! 'hen-tick
  #:description "Counts its calls."
  #:shape '(type object)
  #:handler (lambda (args)
             (set! *ticks* (+ *ticks* 1))
             (number->string *ticks*)))
