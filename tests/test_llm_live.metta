; Live tests: real Gemini calls (needs GEMINI_API_KEY).
; Gemini's wording varies, so we test the SHAPE of what comes back.

!(import! &self ../core/schema)
!(import! &self ../core/llm)

!(add-atom &caps (tool calc "evaluate an arithmetic expression like 2*(3+4)" safe))
!(add-atom &caps (tool web-search "search the web, input is a query" safe))
!(set-goal "What is the population of Paris multiplied by 3?")

; 1. plan: Gemini → (plan ...) → validated → tasks in &wm
!(let $r (make-plan)
      (let $_ (println! (plan-result $r))
           (test (car-atom $r) planned)))
!(println! (tasks (collapse (match &wm (task $i $d $s) ($i $d $s)))))
!(println! (ready-now (ready-tasks)))
!(test (> (size-atom (ready-tasks)) 0) True)

; 2. next step: must be a valid action using a declared tool (or final/ask-user)
!(let $p (propose-next)
      (let $_ (println! (proposal $p))
           (test (is-member (car-atom $p) (action final ask-user)) True)))
