(import scheme (chicken base) (chicken condition) (chicken port) hen-plugin)

(define alpha-pin (config 'alpha-pin #:sources (env "GENERATIONS_TEST_FIXTURE_FOO")))

(register-tool! 'pin
  #:summary "Returns the fixture value."
  #:when "A pin tool answers one value."
  #:description "The host-resolved fixture configuration, every call."
  #:shape '(text)
  #:handler (lambda (args) alpha-pin))
