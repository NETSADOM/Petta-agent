; A REAL request with an invalid key (run with GEMINI_API_KEY=invalid-test-key).
; Checks the network path and that a bad key is a PERMANENT auth error.

!(import! &self ../core/schema)
!(import! &self ../core/llm)

!(let $r (ask-llm "Reply with (final \"hi\")" "say hi")
      (let $_ (println! (bad-key-reply $r))
           (test (index-atom $r 1) auth)))
!(test (temporary-error auth) False)
