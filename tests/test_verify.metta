; Phase 8 tests: multi-layer verification of final answers.

!(import! &self ../core/agent)
!(import! &self "fake_tools.py")
!(import! &self "../capabilities/capability_checks.py")
!(set-config retry-backoff 0)
!(declare-tool upper "uppercase" safe fake_tools.upper)

(= (layers) (collapse (match &wm (verification $n $layer $r) ($n $layer $r))))

; ---------------- layer 1: symbolic ----------------
!(clear-wm)
!(load-plan (plan (task t1 "a") (task t2 "b")))
!(test (index-atom (car-atom (symbolic-problems "x")) 1) (t1 t2))
; the hint names the tools each open task's skills need
!(test (index-atom (car-atom (symbolic-problems "x")) 3) ((t1 (run-first ())) (t2 (run-first ()))))
!(declare-skill hinting "for the hint test" (upper) (hint))
!(add-atom &wm (task-skill t2 hinting))
!(test (index-atom (car-atom (symbolic-problems "x")) 3) ((t1 (run-first ())) (t2 (run-first (upper)))))
!(remove-atom &wm (task-skill t2 hinting))

; the math check: a calc (or run-python) RESULT must be in the observations
!(test (py-call (capability_checks.computed_by_tool "g" "372" "((1 calc \"2480*0.15\" (ok 372)))")) True)
!(test (car-atom (py-call (capability_checks.computed_by_tool "g" "372" "()"))) error)
!(test (car-atom (py-call (capability_checks.computed_by_tool "g" "372" "((1 calc \"2480*x\" (error bad-input)))"))) error)
!(test (py-call (capability_checks.computed_by_tool "g" "5" "((1 run-python \"print(2+3)\" (ok 5)))")) True)
!(set-status t1 completed)
!(set-status t2 completed)
!(test (symbolic-problems "x") ())
!(test (symbolic-problems "   ") (empty-answer))

; ---------------- layer 2: objective (your Python checks) ----------------
!(declare-verifier fake_tools.has_digit)
!(set-goal "count things")
!(test (objective-problems "there are 3") ())
!(test (objective-problems "there are three") ((check-failed fake_tools.has_digit "check did not pass")))
; a crashing verifier counts as a failure, never as a pass
!(declare-verifier fake_tools.broken_verifier)
!(test (car-atom (car-atom (objective-problems "3"))) check-failed)
!(remove-atom &caps (verifier fake_tools.broken_verifier))
; skill verifiers apply only when a task uses that skill
!(declare-skill counting "count" (upper) (count))
!(test (set-skill-verifier counting fake_tools.always_false) (verifier-declared counting fake_tools.always_false))
!(test (set-skill-verifier nope fake_tools.always_false) (error (unknown-skill nope)))
!(test (objective-problems "3") ())                     ; no task uses counting yet
!(load-plan (plan (task t1 "count" (uses counting))))
!(test (objective-problems "3") ((check-failed fake_tools.always_false "check did not pass")))
!(remove-atom &caps (skill-verifier counting fake_tools.always_false))
!(remove-atom &caps (verifier fake_tools.has_digit))

; ---------------- in the loop: objective failure → rejected → fixed → accepted ----------------
!(declare-verifier fake_tools.has_digit)
!(use-script ("(plan (task t1 \"count\"))"
              "(action upper \"x\")" "(task-done t1)"
              "(final \"three\")"                 ; rejected: no digit
              "(final \"3\")"))                   ; accepted
!(test (run-agent "how many?") (done "3"))
!(test (match &wm (step $n finish "three" $o) $o)
       (error (verification-failed ((check-failed fake_tools.has_digit "check did not pass")))))
!(test (layers) ((1 symbolic pass) (1 objective ((check-failed fake_tools.has_digit "check did not pass")))
                 (2 symbolic pass) (2 objective pass) (2 semantic skipped)))
!(remove-atom &caps (verifier fake_tools.has_digit))

; ---------------- layer 3: semantic (a separate Gemini judgement) ----------------
; use-script turns semantic verification off; switch it on and script the verdicts
!(use-script ("(plan (task t1 \"look\"))"
              "(action upper \"paris\")" "(task-done t1)"
              "(final \"Paris has 9 million people\")"
              "(verdict unsupported \"observations only show PARIS, no population\")"
              "(final \"I could only confirm the name: PARIS\")"
              "(verdict supported \"matches the observation\")"))
!(set-config verify-semantic on)
!(test (run-agent "population of paris") (done "I could only confirm the name: PARIS"))
!(test (match &wm (step $n finish "Paris has 9 million people" $o) $o)
       (error (verification-failed ((semantic "observations only show PARIS, no population")))))
!(test (match &wm (verification 2 semantic $r) $r) pass)
; the checker saw the observations and the answer
!(test (py-call (operator.contains (last-prompt) "I could only confirm the name: PARIS")) True)
!(test (py-call (operator.contains (last-prompt) "(ok PARIS)")) True)

; an unreadable verdict is "unknown" → does not block (but is recorded)
!(use-script ("(plan (task t1 \"t\"))" "(task-done t1)" "(final \"ok\")" "hmm, looks fine I guess"))
!(set-config verify-semantic on)
!(test (run-agent "x") (done "ok"))
!(test (match &wm (verification 1 semantic $r) $r) unknown)

; semantic only runs if layers 1-2 pass (no wasted Gemini call)
!(use-script ("(plan (task t1 \"a\") (task t2 \"b\"))" "(task-done t1)"
              "(final \"early\")"
              "(task-done t2)" "(final \"complete\")" "(verdict supported \"fine\")"))
!(set-config verify-semantic on)
!(test (run-agent "x") (done "complete"))
!(test (collapse (match &wm (verification 1 $layer $r) $layer)) (symbolic))

; ---------------- give up honestly: done-unverified ----------------
!(use-script ("(plan (task t1 \"t\"))" "(task-done t1)"
              "(final \"a\")" "(verdict unsupported \"no\")"
              "(final \"b\")" "(verdict unsupported \"no\")"
              "(final \"c\")" "(verdict unsupported \"no\")"))
!(set-config verify-semantic on)
!(test (run-agent "x") (done-unverified "c"))
!(test (episode-confidence (done-unverified "c")) 0.4)
