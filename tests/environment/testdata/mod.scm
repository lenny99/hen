(define *mod-secret* "mod-internal-state")

(define *mod-cfg* (config 'hen-wall-cfg #:sources (env "HEN_WALL_CFG")))

(register-tool!
 'listen
 #:summary "Shows what the model asked."
 #:when "Whenever the wall tool answers one question."
 #:description "Writes the ask back with its host-resolved config value."
 #:shape '(type object
           (properties (text (type string)
                             (description "something to listen to")))
           (required text))
 #:handler (lambda (args) (string-append *mod-cfg* ":" (arg args 'text))))

(register-tool!
 'listen-again
 #:summary "Shows duplication."
 #:when "Whenever the wall tool answers twice."
 #:description "Returns its text."
 #:shape '(type object)
 #:handler (lambda (args) (arg args 'text)))
