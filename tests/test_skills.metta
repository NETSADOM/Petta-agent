; Phase 6 tests: skills (declare, discover, use in plans) + task manager.

!(import! &self ../core/agent)
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)   ; no waiting in tests

!(declare-tool upper "uppercase text" safe fake_tools.upper)
!(declare-tool flaky "always fails" safe fake_tools.always_fails)

; ---------------- declaring skills ----------------
!(test (declare-skill shouting "make text loud" (upper) (shout loud uppercase))
       (declared-skill shouting))
!(test (declare-skill shouting "again" (upper) (x)) (error (duplicate-skill shouting)))
!(declare-skill research "find facts on the web" (web-search) (find search who what))
!(declare-skill retrying "retry flaky services" (flaky) (retry service))

!(test (set-skill-info shouting procedure "1. call upper on the text 2. report it")
       (skill-info-set shouting procedure))
!(set-skill-info shouting output "the uppercased text")
!(set-skill-info shouting procedure "1. call upper 2. report")       ; replaces
!(test (collapse (match &caps (skill-info shouting procedure $t) $t)) ("1. call upper 2. report"))
!(test (set-skill-info shouting colour "red") (error (invalid-skill-key colour)))
!(test (set-skill-info nope output "x") (error (unknown-skill nope)))

; ---------------- discovery (PeTTa ranks, not Gemini) ----------------
!(test (skill-score shouting "please SHOUT this, make it loud") 2)
!(test (skill-score shouting "nothing relevant") 0)
; research matches the words but its tool web-search is missing → not offered
!(test (relevant-skills "find who will shout") (shouting))
; best match first
!(test (relevant-skills "shout loud in uppercase, then retry") (shouting retrying))   ; 3 vs 1
!(test (relevant-skills "retry the service, retry it, shout") (retrying shouting))
!(test (relevant-skills "hello") ())
!(test (skill-detail shouting)
       (shouting "make text loud" ((output "the uppercased text") (procedure "1. call upper 2. report"))))

; ---------------- plans that use skills ----------------
!(test (check-plan (plan (task t1 "a" (uses shouting)) (task t2 "b" (uses shouting) (after t1))))
       (plan (task t1 "a" (uses shouting)) (task t2 "b" (uses shouting) (after t1))))
; a skill that is unavailable, unknown or really a tool name: the plan is kept,
; the (uses ..) is ignored when loading
!(test (check-plan (plan (task t1 "a" (uses research)))) (plan (task t1 "a" (uses research))))
!(test (check-plan (plan (task t1 "a" (uses dancing)))) (plan (task t1 "a" (uses dancing))))
!(load-plan (plan (task t1 "a" (uses dancing)) (task t2 "b" (uses shouting))))
!(test (skills-of-task t1) ())
!(test (skills-of-task t2) (shouting))
!(test (check-plan (plan (task t1 "a" (uses)))) (invalid bad-task))
!(test (check-plan (plan (task t1 "a" (colour red)))) (invalid bad-task))
!(test (check-plan (plan (task t1 "a") (task t2 "b" (after t1 t3)))) (invalid unknown-dependency))

!(load-plan (plan (task t1 "shout hi" (uses shouting))
                  (task t2 "shout bye" (after t1))
                  (task t3 "combine" (after t1 t2))))
!(test (skills-of-task t1) (shouting))
!(test (skills-of-task t2) ())
!(test (collapse (match &wm (depends t3 $d) $d)) (t1 t2))

; ---------------- task selection ----------------
!(test (next-task) t1)
!(test (current-task) t1)
!(test (start-current-task) t1)
!(test (status-of t1) running)
!(test (current-task) t1)                      ; running task stays current
!(set-status t1 completed)
!(test (current-task) t2)

; the current task's skill guide reaches the ACT prompt; recommendations reach PLAN
!(set-status t2 pending)
!(clear-tasks)
!(load-plan (plan (task t1 "shout hi" (uses shouting))))
!(set-goal "shout hello loud")
!(test (py-call (operator.contains (act-request) "1. call upper 2. report")) True)
!(test (py-call (operator.contains (plan-request) "the uppercased text")) True)

; ---------------- failure spreads down the chain ----------------
!(load-plan (plan (task t1 "a") (task t2 "b" (after t1)) (task t3 "c" (after t2)) (task t4 "d")))
!(test (fail-task t1) (t2 t3))
!(test (status-of t3) blocked)
!(test (status-of t4) pending)
!(test (next-task) t4)

; ---------------- full loop: skill plan, task-failed, replan, missing capability ----------------
!(use-script ("(plan (task t1 \"get data\") (task t2 \"shout it\" (after t1) (uses shouting)))"
              "(action flaky \"x\")"
              "(task-failed t1 \"service down\")"
              "(replan \"t1 failed, shout without data\")"
              "(plan (task t1 \"shout directly\" (uses shouting)))"
              "(action upper \"hi\")"
              "(missing-capability \"a weather API\")"
              "(task-done t1)"
              "(final \"HI\")"))
!(test (run-agent "shout hi") (done "HI"))
!(test (match &wm (step $n task-failed t1 $o) $o) (ok (blocked (t2))))
!(test (match &wm (step $n replan $w $o) $o) (ok (planned 1)))
; the replanned task was marked running when acted on, then completed
!(test (status-of t1) completed)
; the capability gap is remembered in long-term memory (&kb, saved to disk)
!(test (recall (capability-gap $x)) (((capability-gap "a weather API") 0.5)))
; the replan prompt carried what had happened before
!(test (size-atom (collapse (match &wm (step $n $t $i $o) $n))) 6)

; ---------------- replan limit ----------------
!(use-script ("(plan (task t1 \"a\"))"
              "(replan \"1\")" "(plan (task t1 \"a\"))"
              "(replan \"2\")" "(plan (task t1 \"a\"))"
              "(replan \"3\")"
              "(task-done t1)" "(final \"ok\")"))
!(test (run-agent "x") (done "ok"))
!(test (match &wm (step $n replan "3" $o) $o) (error replan-limit))
