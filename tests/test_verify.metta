; Tests: multi-layer verification of final answers.

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

; the checks see what the agent READ, not a cut of it: a fact at character 6000
; of a page (the old cut was 4000) counts as observed
!(clear-wm)
!(set-goal "dropout history")
!(let $t (py-call (fake_tools.late_fact 6000)) (record-step http-get "https://w" (ok $t)))
!(declare-verifier capability_checks.number_is_observed)
!(test (objective-problems "introduced in 2012") ())
!(test (car-atom (car-atom (objective-problems "introduced in 2013"))) check-failed)
!(remove-atom &caps (verifier capability_checks.number_is_observed))
; the semantic check shares its budget: one long step is shown whole
!(test (py-call (fake_tools.has (all-steps-repr) "in 2012")) True)
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
!(test (py-call (operator.contains (last-prompt) "\"ok\", \"PARIS\"")) True)

; an unreadable verdict is asked for again AT ONCE: no rejection, no lost turn
!(use-script ("(plan (task t1 \"t\"))" "(task-done t1)" "(final \"ok\")" "hmm, looks fine I guess"
              "(verdict supported \"checked\")"))
!(set-config verify-semantic on)
!(test (run-agent "x") (done "ok"))
!(test (match &wm (verification 1 semantic $r) $r) pass)
!(test (count-errors finish) 0)

; a checker that stays unavailable rejects the final (never success), but in its
; OWN budget: here the content budget (2) is still whole after it, so the
; answer gets both of its content retries and then passes
!(use-script ("(plan (task t1 \"t\"))" "(task-done t1)"
              "(final \"a\")" "unparseable" "unparseable"
              "(final \"b\")" "(verdict unsupported \"no\")"
              "(final \"c\")" "(verdict unsupported \"no\")"
              "(final \"d\")" "(verdict supported \"checked\")"))
!(set-config verify-semantic on)
!(test (run-agent "x") (done "d"))
!(test (rejections-of checker) 1)
!(test (content-rejections) 2)

; repairing plan status does not consume the factual-answer rejection budget;
; verification feedback remains visible after successful bookkeeping calls.
; Explicitly close synthesis before asking the factual checker to judge it.
!(use-script ("(plan (task t1 \"research\") (task t2 \"summarize\" (after t1)))"
              "(action upper \"dropout\")" "(task-done t1)"
              "(task-done t2)"
              "(final \"unsupported one\")" "(verdict unsupported \"remove unsupported claims\")"
              "(task-done t2)"
              "(final \"unsupported two\")" "(verdict unsupported \"still unsupported\")"
              "(final \"DROPOUT\")" "(verdict supported \"matches observed text\")"))
!(set-config verify-semantic on)
!(test (run-agent "research dropout and summarize it") (done "DROPOUT"))
!(test (count-errors finish) 2)
!(test (content-rejections) 2)
!(test (py-call (operator.contains (act-request) "final-feedback")) True)
!(test (py-call (operator.contains (act-request) "still unsupported")) True)

; a plain-text summary after the format repair is only a final PROPOSAL;
; unsupported prose is still rejected by the semantic checker.
!(set-config repair-replies on)
!(use-script ("(plan (task t1 \"summarize\"))" "(task-done t1)" ""
              "Dropout disables selected activations during training. It helps reduce overfitting in neural networks. This extra claim has no supporting source."
              "(verdict unsupported \"the extra claim is unsupported\")"
              "(final \"Supported summary\")" "(verdict supported \"checked\")"))
!(set-config verify-semantic on)
!(test (run-agent "summarize dropout") (done "Supported summary"))
!(test (count-errors finish) 1)
!(set-config repair-replies off)

; End-to-end: the checker sees a late source fact despite many bookkeeping
; steps, and does not mistake an earlier rejected answer for source evidence.
!(use-script ("(verdict supported \"the source contains the date\")"))
!(set-config verify-semantic on)
!(clear-wm)
!(set-goal "check the observed date")
!(let $source (py-call (fake_tools.late_fact 12000))
       (record-step http-get "https://example.org/source" (ok $source)))
!(collapse (let $n (superpose (1 2 3 4 5 6 7 8 9 10))
                (record-step task-done $n (ok completed))))
!(record-step finish "UNTRUSTED EARLIER DRAFT" (error unsupported))
!(test (verify-answer "The source says in 2012.") ())
!(test (py-call (operator.contains (last-prompt) "in 2012")) True)
!(test (py-call (operator.contains (last-prompt) "UNTRUSTED EARLIER DRAFT")) False)
!(test (count-errors finish) 1)

 ; ---------------- dependencies do not complete pending work ----------------
; Even after research succeeds, a pending save task must remain unfinished.
!(use-script ("(plan (task t1 \"research\") (task t2 \"save report\" (after t1)))"
              "(action upper \"dropout\")" "(task-done t1)"
              "(final \"DROPOUT\")"))
!(set-config verify-semantic off)
!(set-config max-iterations 3)
!(test (car-atom (run-agent "research and save report")) stopped)
!(test (status-of t2) pending)
!(set-config max-iterations 40)
!(test (count-errors finish) 1)
!(test (rejections-of structural) 1)
; Synthesis can explicitly close in the same reply as its final answer.
!(use-script ("(plan (task t1 \"research\") (task t2 \"summarize\" (after t1)))"
              "(action upper \"dropout\")" "(task-done t1)"
              "(actions (task-done t2) (final \"DROPOUT\"))"))
!(test (run-agent "research dropout and summarize it") (done "DROPOUT"))
!(test (count-errors finish) 0)
!(test (status-of t2) completed)
; no evidence behind it (t1 closed without any tool): t2 stays open → rejected
!(use-script ("(plan (task t1 \"research\") (task t2 \"summarize\" (after t1)))"
              "(task-done t1)" "(final \"from memory\")"
              "(task-done t2)" "(final \"from memory\")"))
!(test (run-agent "research and summarize") (done "from memory"))
!(test (car-atom (index-atom (match &wm (step 2 finish $a $o) $o) 1))
       verification-failed)
; a task WITHOUT dependencies is never closed this way: answering before any
; research is still rejected
!(use-script ("(plan (task t1 \"what is dropout\"))"
              "(final \"from memory\")"
              "(action upper \"dropout\")" "(final \"DROPOUT\")"))
!(test (run-agent "what is dropout") (done "DROPOUT"))
!(test (count-errors finish) 1)

; (task-done t1) twice: the second is a no-op, not shown or recorded again
!(use-script ("(plan (task t1 \"t\"))" "(action upper \"x\")"
              "(task-done t1)" "(task-done t1)" "(final \"X\")"))
!(test (run-agent "x") (done "X"))
!(test (size-atom (collapse (match &wm (step $n task-done t1 $o) $n))) 1)
!(test (mark-done t1) (ok already-completed))

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
!(test (episode-confidence (done-unverified "c")) 0)   ; not verified = not kept

; an unreachable checker also blocks; exhausting retries is visibly incomplete
; (each final asks the checker twice: the first try and the immediate retry)
!(use-script ("(plan (task t1 \"t\"))" "(task-done t1)"
              "(final \"a\")" "unparseable" "unparseable"
              "(final \"b\")" "unparseable" "unparseable"
              "(final \"c\")" "unparseable" "unparseable"))
!(set-config verify-semantic on)
!(test (run-agent "x") (done-unverified "c"))
!(test (count-errors finish) 2)
!(use-script ())
!(set-config verify-semantic on)
!(clear-wm)
!(set-goal "check with an unavailable model")
!(test (car-atom (car-atom (verify-answer "draft"))) checker-unavailable)
!(test (match &wm (verification 1 semantic $r) $r) unknown)
