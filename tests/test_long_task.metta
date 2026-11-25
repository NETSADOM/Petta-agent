; The agent loop on a LONG task (27 turns), with a scripted model:
;   - each turn: prompt → model → parse into tool calls → run → results in the next prompt
;   - several calls in one reply run in order, in one turn
;   - an unknown tool name comes back to the model as an error; the run goes on
;   - a failure is read and a different call is made
;   - the goal and an early finding are still in the prompt at turn 27
;   - the agent itself decides it is done and returns the answer for the user
; No stdin is needed: every tool here is safe.

!(import! &self ../core/agent)
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)
!(declare-tool upper "uppercase text" safe fake_tools.upper)
!(declare-tool flaky "always fails" safe fake_tools.always_fails)

(= (outcomes) (collapse (match &wm (step $n $t $i $o) ($n $t $o))))

!(use-script
  ("(plan (task t1 \"collect the codes\") (task t2 \"report the first code\" (after t1)))"
   ; turn 1: an early finding the model needs at the very end
   "(action upper \"code-4711\")"
   ; turn 2: three calls in one reply, one of them a tool that does not exist
   "(action upper \"a\") (action nosuch \"z\") (action upper \"b\")"
   ; turns 3-22: twenty more steps of work
   "(action upper \"w3\")"  "(action upper \"w4\")"  "(action upper \"w5\")"  "(action upper \"w6\")"
   "(action upper \"w7\")"  "(action upper \"w8\")"  "(action upper \"w9\")"  "(action upper \"w10\")"
   "(action upper \"w11\")" "(action upper \"w12\")" "(action upper \"w13\")" "(action upper \"w14\")"
   "(action upper \"w15\")" "(action upper \"w16\")" "(action upper \"w17\")" "(action upper \"w18\")"
   "(action upper \"w19\")" "(action upper \"w20\")" "(action upper \"w21\")" "(action upper \"w22\")"
   ; turn 23: a failure; turn 24: something different
   "(action flaky \"check\")"
   "(action upper \"check another way\")"
   "(task-done t1)"
   "(task-done t2)"
   "(final \"the first code was CODE-4711\")"))

!(test (run-agent "collect the codes and report the first one") (done "the first code was CODE-4711"))

; 27 turns, 28 steps (turn 2 ran 3 calls)
!(test (current-turn) 27)
!(test (step-count) 28)

; the batch: all three calls ran in order; the unknown one is an error, not a stop
!(test (repr (index-atom (outcomes) 1)) "(2 upper (ok A))")
!(test (let (3 nosuch (error (unknown-tool $n $avail))) (index-atom (outcomes) 2) $n) nosuch)
!(test (repr (index-atom (outcomes) 3)) "(4 upper (ok B))")
!(test (count-errors gemini) 0)

; the failure, then a different call that worked
!(test (repr (index-atom (outcomes) 24)) "(25 flaky (error service unavailable))")
!(test (repr (index-atom (outcomes) 25)) "(26 upper (ok CHECK ANOTHER WAY))")

; the prompt of the LAST turn still had the goal, the plan, the early finding
; (step 1, now in short form) and the turn counter
!(test (py-call (operator.contains (last-prompt) "collect the codes and report the first one")) True)
!(test (py-call (operator.contains (last-prompt) "CODE-4711")) True)
!(test (py-call (operator.contains (last-prompt) "PROGRESS: turn 27 of 40")) True)
!(test (py-call (operator.contains (last-prompt) "(t1 \"collect the codes\" completed)")) True)

; near the limit, the model is told to wrap up
!(test (py-call (operator.contains (py-call (prompts.progress_text 38 40)) "FEW TURNS LEFT")) True)
!(test (py-call (operator.contains (py-call (prompts.progress_text 10 40)) "FEW TURNS LEFT")) False)

; three sporadic bad replies over a long run are tolerated (only IN A ROW they stop it)
!(use-script ("(plan (task t1 \"t\"))"
              "lol" "(action upper \"1\")" "lol" "(action upper \"2\")" "lol" "(action upper \"3\")"
              "(task-done t1)" "(final \"fine\")"))
!(test (run-agent "x") (done "fine"))
!(test (count-errors gemini) 3)

; ---------------- several goals in one session ----------------
; the previous goals of this session (bounded) are in the prompt of the next one
!(test (py-call (operator.contains (last-prompt) "Earlier tasks in this session")) True)
!(test (py-call (operator.contains (last-prompt) "task 1: goal: collect the codes and report the first one")) True)
!(test (py-call (operator.contains (last-prompt) "the first code was CODE-4711")) True)
!(test (py-call (session.count)) 2)
; at most 5 tasks are kept, each clipped: the prompt does not grow with the session
!(py-call (session.record "g3" (repr (done "a"))))
!(py-call (session.record "g4" (repr (done "a"))))
!(py-call (session.record "g5" (repr (done "a"))))
!(py-call (session.record "g6" (py-call (fake_tools.big_text 1))))
!(test (py-call (operator.contains (py-call (session.summary)) "task 1:")) False)
!(test (< (py-call (toolrunner.length (py-call (session.summary)))) 2200) True)

; ---------------- stuck: every step fails → stop and tell the user ----------------
!(use-script ("(plan (task t1 \"t\"))"
              "(action flaky \"1\")" "(action flaky \"2\")" "(action flaky \"3\")" "(action flaky \"4\")"
              "(action flaky \"5\")" "(action flaky \"6\")" "(action flaky \"7\")" "(action flaky \"8\")"
              "(action flaky \"9\")" "(final \"never\")"))
!(test (run-agent "x") (stopped (no-progress (failed-in-a-row 8))))
!(test (step-count) 8)
!(test (let (stop-report (goal $g) (reason $r) $p (recent-errors $e)) (stuck-report (stopped (no-progress x)))
            (size-atom $e))
       3)

; ---------------- the prompt stays bounded ----------------
!(test (py-call (operator.eq (py-call (prompts.cap "abcdefghij" 4)) "[6 older characters cut]ghij")) True)
; 50 000 characters of step history → at most STEPS_MAX (28 000) in the prompt
!(test (< (py-call (toolrunner.length (py-call (prompts.act_prompt "g" "t" "c" (py-call (fake_tools.big_text 1 50000)) "tools" "facts" "none" 1 40 "none")))) 30000) True)
