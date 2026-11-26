; Tests: the full agent loop with a SCRIPTED brain (no API key needed).
; Scripted replies still go through parsing, validation, permissions, tools.
; stdin (piped by run_tests.sh) answers the interactive questions, in order:
;   1. "n"     deny write-note       (scenario 6)
;   2. "y"     approve write-note    (scenario 7)
;   3. "blue"  answer to ask-user    (scenario 8)

!(import! &self ../core/agent)
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)   ; no waiting in tests

!(add-atom &caps (tool upper "uppercase text" safe))
!(add-atom &caps (tool-impl upper fake_tools.upper))
!(add-atom &caps (tool flaky "always fails" safe))
!(add-atom &caps (tool-impl flaky fake_tools.always_fails))
!(add-atom &caps (tool buggy "raises" safe))
!(add-atom &caps (tool-impl buggy fake_tools.crash))
!(add-atom &caps (tool raw "returns a bare value" safe))
!(add-atom &caps (tool-impl raw fake_tools.raw_value))
!(add-atom &caps (tool write-note "save a note" needs-approval))
!(add-atom &caps (tool-impl write-note fake_tools.write_note))
!(add-atom &caps (tool ghost "declared, no implementation" safe))

(= (outcomes) (collapse (match &wm (step $n $t $i $o) ($n $t $o))))

; ===== 1. multi-step success: plan → 2 actions → tasks done → final =====
!(use-script ("(plan (task t1 \"shout hello\") (task t2 \"shout world\" (after t1)))"
              "(action upper \"hello\")"
              "(task-done t1)"
              "(action upper \"world\")"
              "(task-done t2)"
              "(final \"HELLO WORLD\")"))
!(test (run-agent "shout hello world") (done "HELLO WORLD"))
!(test (outcomes) ((1 upper (ok HELLO)) (2 task-done (ok completed))
                   (3 upper (ok WORLD)) (4 task-done (ok completed))))
!(test (all-done) True)
; the observation from step 1 was in the context Gemini saw afterwards
!(test (py-call (operator.contains (last-prompt) "HELLO")) True)

; ===== 2. the model invents a tool → never runs; the error (with the real tool
;          names) is that call's result, the model reads it and goes on =====
!(use-script ("(plan (task t1 \"answer\"))"
              "(action delete-everything \"/\")"
              "(task-done t1)"
              "(final \"ok\")"))
!(test (run-agent "x") (done "ok"))
!(test (let (1 $t (error (unknown-tool $n (available $names)))) (index-atom (outcomes) 0)
            ($t $n (is-member upper $names)))
       (delete-everything delete-everything True))
!(test (count-errors gemini) 0)                       ; not a "bad reply"

; ===== 3. same call fails twice → the third is REFUSED with advice; the model
;          changes approach and finishes =====
!(use-script ("(plan (task t1 \"fetch\"))"
              "(action flaky \"x\")"
              "(action flaky \"x\")"
              "(action flaky \"x\")"
              "(action upper \"another way\")"
              "(task-done t1)"
              "(final \"recovered\")"))
!(test (run-agent "x") (done "recovered"))
!(test (let (3 flaky (error (repeated-call $k $why))) (index-atom (outcomes) 2) $k) 2)
!(test (repr (index-atom (outcomes) 3)) "(4 upper (ok ANOTHER WAY))")

; ===== 3b. the model keeps insisting → stop after max-refusals refusals =====
!(use-script ("(plan (task t1 \"fetch\"))"
              "(action flaky \"x\")" "(action flaky \"x\")" "(action flaky \"x\")"
              "(action flaky \"x\")" "(action flaky \"x\")" "(final \"never reached\")"))
!(test (run-agent "x") (stopped (repeated-failure flaky "x")))
!(test (refusals) 3)

; ===== 4. iteration limit: the user is told how far the plan got =====
!(set-config max-iterations 3)
!(use-script ("(plan (task t1 \"loop\"))"
              "(action upper \"a\")" "(action upper \"b\")" "(action upper \"c\")"
              "(action upper \"d\")" "(action upper \"e\")"))
!(test (run-agent "x") (stopped (iteration-limit (progress (turns 3) (steps 3) (tasks-done 0 of 1) (open (t1))))))
!(test (step-count) 3)
!(set-config max-iterations 40)

; ===== 5. "final" with open tasks is rejected; after max-structural-rejections (5) → done-unverified =====
!(use-script ("(plan (task t1 \"a\") (task t2 \"b\"))"
              "(final \"too early\")"
              "(task-done t1)"
              "(final \"still early\")"
              "(final \"early 3\")" "(final \"early 4\")" "(final \"early 5\")"
              "(final \"give up waiting\")"))
!(test (run-agent "x") (done-unverified "give up waiting"))
!(test (count-errors finish) 5)   ; max-structural-rejections
!(test (match &wm (step 1 finish $a (error (verification-failed (($u $open $why $hints))))) ($u $open $hints))
       (unfinished (t1 t2) ((t1 (run-first ())) (t2 (run-first ())))))

; ===== 5b. final closes the task being worked on: no extra task-done turn =====
!(use-script ("(plan (task t1 \"shout\"))"
              "(action upper \"hi\")"
              "(final \"HI\")"))
!(test (run-agent "shout hi") (done "HI"))
!(test (count-errors finish) 0)
!(test (status-of t1) completed)
!(test (match &wm (step $n task-done t1 $o) $o) (ok completed-with-final))

; a task never started still blocks the final answer
!(use-script ("(plan (task t1 \"shout\") (task t2 \"whisper\"))"
              "(action upper \"hi\")"
              "(final \"HI\")"
              "(task-done t2)"
              "(final \"HI\")"))
!(test (run-agent "shout and whisper") (done "HI"))
!(test (count-errors finish) 1)
!(test (match &wm (step $n finish $a (error (verification-failed (($u $open $why $hints))))) $open) (t2))

; ===== 5c. several tasks done in ONE reply =====
!(use-script ("(plan (task t1 \"a\") (task t2 \"b\") (task t3 \"c\"))"
              "(task-done t1 t2 t3)"
              "(final \"all done\")"))
!(test (run-agent "abc") (done "all done"))
!(test (collapse (match &wm (step $n task-done $id (ok completed)) $id)) (t1 t2 t3))
!(test (check-proposal (task-done t1 "t2")) (invalid bad-shape))

; ===== 5b. a batch credits its calls to EVERY task it closes =====
; t2 never ran a call of its own (the batch's calls go to the running task t1):
; it gets the calls of the closing turn. All failed → t2 is not done either.
!(use-script ("(plan (task t1 \"a\") (task t2 \"b\"))"
              "(actions (action flaky \"x\") (task-done t1 t2))"
              "(actions (action upper \"y\") (task-done t1 t2))"
              "(final \"Y\")"))
!(test (run-agent "ab") (done "Y"))
!(test (collapse (match &wm (step $n task-done t2 (error (no-evidence t2 $why))) $n)) (3))
!(test (collapse (match &wm (step $n task-done t2 (ok completed)) $n)) (6))
; a task closed in a turn that ran NO call (pure reasoning) still closes
!(use-script ("(plan (task t1 \"think\"))" "(task-done t1)" "(final \"thought\")"))
!(test (run-agent "think") (done "thought"))

; ===== 5c. the run score: REPORT ONLY, the outcome dominates =====
; (2 turns, nothing wasted: 60 + 40 - 1 for the second turn)
!(test (index-atom (run-score (done "thought") 0) 1) 99)
!(test (index-atom (run-score (blocked "x") 0) 1) 40)
!(test (index-atom (run-score (done-unverified "x") 0) 1) 20)
!(test (index-atom (run-score (stopped too-many-invalid-replies) 0) 1) 0)
; wasted LLM calls lower a done run's score, but never below 60
; (9 calls for 2 turns: 5 beyond the expected 2 + 2 → 60 + 40 - 1 - 5)
!(test (index-atom (run-score (done "thought") 9) 1) 94)
!(test (index-atom (run-score (done "thought") 500) 1) 60)

; ===== 6. needs-approval tool, user says "n" → denied, tool NOT run =====
!(use-script ("(plan (task t1 \"save\"))"
              "(action write-note \"secret\")"
              "(task-done t1)"                                ; refused: its only call failed
              "(task-failed t1 \"the user denied the write\")"
              "(final \"could not save: you denied the write\")"))
!(test (run-agent "x") (done "could not save: you denied the write"))
!(test (index-atom (outcomes) 1) (2 task-done (error (no-evidence t1 "every tool call for this task failed - a failed call is not completed work: fix it and run it again, or (task-failed ID \"why\")"))))
!(test (collapse (status-of t1)) (failed))
!(test (index-atom (outcomes) 0) (1 write-note (error denied-by-user)))
!(test (match &wm (approval write-note $i $yes) $yes) false)
!(test (py-call (fake_tools.note_count)) 0)

; ===== 7. needs-approval tool, user says "y" → runs =====
!(use-script ("(plan (task t1 \"save\"))"
              "(action write-note \"hello\")"
              "(task-done t1)"
              "(final \"saved\")"))
!(test (run-agent "x") (done "saved"))
!(test (index-atom (outcomes) 0) (1 write-note (ok saved)))
!(test (py-call (fake_tools.note_count)) 1)

; ===== 8. ask-user → answer goes into working memory =====
!(use-script ("(plan (task t1 \"ask\"))"
              "(ask-user \"favourite colour?\")"
              "(task-done t1)"
              "(final \"you like blue\")"))
!(test (run-agent "x") (done "you like blue"))
!(test (match &wm (step 1 ask-user $q $a) $a) (ok blue))

; ===== 9. broken tools never crash the loop =====
!(use-script ("(plan (task t1 \"t\"))"
              "(action buggy \"x\")"
              "(action ghost \"x\")"
              "(action raw \"x\")"
              "(task-done t1)"
              "(final \"survived\")"))
!(test (run-agent "x") (done "survived"))
!(test (cdr-atom (outcomes)) ((2 ghost (error no-implementation))
                             (3 raw (ok 42)) (4 task-done (ok completed))))
; the exception message is kept, so Gemini (and you) can see what broke
!(test (match &wm (step 1 buggy $i (error $m)) (py-call (.startswith $m "exception RuntimeError: tool bug"))) True)

; ===== 10. garbage replies → stop after 3 =====
!(use-script ("(plan (task t1 \"t\"))" "lol" "(dance)" "(action)" "(final \"x\")"))
!(test (run-agent "x") (stopped too-many-invalid-replies))

; ===== 10b. repair-replies on (the CLI): an unusable reply is asked for again AT ONCE =====
!(set-config repair-replies on)
!(use-script ("(plan (task t1 \"t\"))" "(task-done t1)" "## Papers\n**A** and **B**" "(final \"repaired\")"))
!(test (run-agent "x") (done "repaired"))
; no turn was lost: the prose never became a step
!(test (collapse (match &wm (step $n gemini $i $o) $n)) ())
; the second request showed the model what it sent and the format
!(test (let $p (last-prompt) (py-call (.__contains__ $p "COULD NOT BE USED"))) True)
!(test (let $p (last-prompt) (py-call (.__contains__ $p "## Papers"))) True)
; still unusable after the repair: counted as before, 3 in a row stop the run
!(use-script ("(plan (task t1 \"t\"))" "lol" "lol" "lol" "lol" "lol" "lol" "(final \"x\")"))
!(test (run-agent "x") (stopped too-many-invalid-replies))
; an EMPTY reply is repaired in the same turn: no step, no lost turn
!(use-script ("(plan (task t1 \"t\"))" "(task-done t1)" "" "(final \"after-empty\")"))
!(test (run-agent "x") (done "after-empty"))
!(test (collapse (match &wm (step $n gemini $i $o) $n)) ())
!(test (let $p (last-prompt) (py-call (.__contains__ $p "WAS EMPTY"))) True)
; a wrong shape is asked for again too
!(use-script ("(plan (task t1 \"t\"))" "(task-done t1)" "(action)" "(final \"reshaped\")"))
!(test (run-agent "x") (done "reshaped"))
!(set-config repair-replies off)

; ===== 10c. a batch may END with a final: close the open task and answer in ONE reply =====
; (what models send after a final was rejected for an open task)
!(use-script ("(plan (task t1 \"get\") (task t2 \"summarize\" (after t1)))"
              "(action raw \"x\")"
              "(task-done t1 t2) (final \"both\")"))
!(test (run-agent "x") (done "both"))
; the final still goes through verification: an open task with failed work rejects it
!(use-script ("(plan (task t1 \"t\"))" "(action ghost \"x\") (final \"too soon\")"
              "(action raw \"x\")" "(final \"after work\")"))
!(test (run-agent "x") (done "after work"))
!(test (collapse (match &wm (step $n finish $a $o) $n)) (2))

; ===== 11. bad plan → sent back once to be corrected; still bad → continue without a plan =====
!(use-script ("not a plan" "still not a plan" "(final \"fine\")"))
!(test (run-agent "x") (done "fine"))

; ===== 12. task-done for a task that doesn't exist =====
!(use-script ("(plan (task t1 \"t\"))" "(task-done t7)" "(task-done t1)" "(final \"ok\")"))
!(test (run-agent "x") (done "ok"))
!(test (index-atom (outcomes) 0) (1 task-done (error unknown-task)))

; ===== 13. real Gemini brain, no key → permanent error → stops at once =====
!(set-config brain gemini)
!(test (let (stopped (error $kind $msg)) (run-agent "x") $kind) config)
