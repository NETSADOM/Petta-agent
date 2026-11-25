; Tests: the agent takes no unnecessary steps and draws no wrong conclusions.
;   no planning call for simple goals, task-done inside a batch, no semantic LLM
;   check when calc already proves the answer, one retry for web tools, the
;   verifier sees whole observations, recoveries and episodes only from real work.

!(import! &self ../core/agent)
!(import! &self ../my_capabilities)
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)
!(declare-tool upper "uppercase text" safe fake_tools.upper)
!(declare-tool always-fails "a tool that fails" safe fake_tools.always_fails)

(= (outcomes) (collapse (match &wm (step $n $t $i $o) ($n $t $o))))

; ---------------- simple goals: no planning LLM call ----------------
!(test (py-call (text.is_simple_goal "what is 15 percent of 2480")) True)
!(test (py-call (text.is_simple_goal "find papers, summarize them and save them")) False)
!(test (py-call (text.is_simple_goal "read sales.csv and compute the total")) False)
!(set-config fast-plan on)
!(use-script ("(action calc \"2480 * 15 / 100\")"            ; turn 1: no plan reply was needed
              "(final \"15 percent of 2480 is 372\")"))
!(test (run-agent "what is 15 percent of 2480") (done "15 percent of 2480 is 372"))
!(test (collapse (match &wm (task-skill t1 $s) $s)) (math))
!(set-config fast-plan off)

; ---------------- task-done inside a batch: no separate turn ----------------
!(use-script ("(plan (task t1 \"a\") (task t2 \"b\"))"
              "(actions (action upper \"a\") (task-done t1) (action upper \"b\"))"
              "(final \"A B\")"))
!(test (run-agent "two tasks") (done "A B"))
!(test (repr (outcomes)) "((1 upper (ok A)) (2 task-done (ok completed)) (3 upper (ok B)) (4 task-done (ok completed-with-final)))")
!(test (check-proposal (actions (task-done t1) (action upper "x"))) (actions (task-done t1) (action upper "x")))
!(test (check-proposal (actions (task-done "t1"))) (invalid bad-shape))

; ---------------- calc proves the answer: no semantic LLM check ----------------
!(use-script ("(plan (task t1 \"compute\" (uses math)))"
              "(action calc \"6 * 7\")"
              "(final \"6 times 7 is 42\")"))          ; nothing left in the script for a verify call
!(set-config verify-semantic on)
!(test (run-agent "what is 6 times 7") (done "6 times 7 is 42"))
!(test (collapse (match &wm (verification $n semantic $r) $r)) (skipped-proven))
!(set-config verify-semantic off)

; ---------------- one retry for web tools, the default elsewhere ----------------
!(test (tool-retries http-get) 1)
!(test (tool-retries web-search) 1)
!(test (tool-retries calc) (config-value max-retries))

; ---------------- the verifier sees whole observations, not 600 characters ----------------
!(clear-wm)
!(record-step chatty "page" (ok (py-call (fake_tools.long_text 3000))))
!(test (> (py-call (toolrunner.length (all-steps-repr))) 2500) True)

; ---------------- recoveries: only a real replacement tool counts ----------------
!(clear-wm)
!(record-step always-fails "x" (error "service unavailable"))
!(record-step read-skill "math" (ok loaded))                  ; not a replacement
!(test (first-success-after 1 always-fails) none)
!(record-step upper "x" (ok X))                               ; a work tool, within 3 steps
!(test (first-success-after 1 always-fails) upper)
!(test (work-tool read-skill) False)
!(test (work-tool calc) True)

; ---------------- a helper's sub-task is not stored as an episode ----------------
!(use-script ("(plan (task t1 \"t\"))"
              "(action delegate \"helper sub-task words\")"
              "(plan (task t1 \"sub\"))"
              "(action upper \"h\")"
              "(final \"H\")"
              "(final \"parent done H\")"))
!(test (run-agent "parent goal words") (done "parent done H"))
!(test (collapse (match &kb (fact (episode "helper sub-task words" $t $a) $m) yes)) ())
!(test (collapse (match &kb (fact (episode "parent goal words" $t $a) $m) $t)) ((tools)))   ; delegate is not a work tool
