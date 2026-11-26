; Tests: safety and honest completion.
;   1 shell options are checked, not just command names
;   2 multiline tool input arrives exactly as written
;   3 the notebook keeps findings all run, bounded
;   4 no success without evidence; done-unverified is not done
;   5 no guessing when the user did not answer
;   6 every memory write passes the memory gates
;   7 dependency cycles and self-dependencies are rejected and sent back
;   8 the whole prompt is bounded
; stdin is /dev/null: every approval is "no", every question goes unanswered.

!(import! &self ../core/agent)
!(import! &self ../my_capabilities)
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)
!(declare-tool upper "uppercase text" safe fake_tools.upper)
!(declare-tool always-fails "a tool that fails" safe fake_tools.always_fails)

(= (outcomes) (collapse (match &wm (step $n $t $i $o) ($n $t $o))))

; ---------------- 1. shell: options and operands decide, not just the name ----------------
!(test (py-call (fake_tools.shell_rules_ok)) True)
!(test (py-call (agent_tools.shell_is_read_only "git diff --output=file")) False)
!(test (py-call (agent_tools.shell_is_read_only "git branch --delete=name")) False)
!(test (py-call (agent_tools.shell_is_read_only "sort --out=result.txt input.txt")) False)
!(test (py-call (agent_tools.shell_is_read_only "git diff --out=result.patch")) False)

; ---------------- 2. multiline content is preserved ----------------
; malformed JSON plans are ordinary invalid replies and can be corrected
!(test (parse-reply "{\"plan\":[null]}") (invalid no-expression))
!(test (parse-reply "{\"plan\":[1]}") (invalid no-expression))
!(use-script ("{\"plan\":[null]}" "(plan (task t1 \"shout\"))"
              "(action upper \"ok\")" "(final \"OK\")"))
!(test (run-agent "shout ok") (done "OK"))
!(test (py-call (fake_tools.is_multiline (index-atom (parse-reply (py-call (fake_tools.multiline_json_reply))) 2))) True)
; raw newlines inside a JSON string (invalid strict JSON, common in model replies)
!(test (py-call (fake_tools.is_two_lines (index-atom (parse-reply (py-call (fake_tools.multiline_raw_json_reply))) 2))) True)

; gpt-oss native tool calls (Groq 400 tool_use_failed) are recovered as the reply
!(test (py-call (fake_tools.gpt_oss_replies_ok)) True)

; ---------------- 3. the notebook ----------------
!(clear-wm)
!(test (execute note "found: the API needs a key") (ok (noted (n 1) found)))
!(test (execute note "todo: write the table") (ok (noted (n 2) todo)))
!(test (car-atom (execute note "idea: no such kind")) error)
!(test (execute note "drop: n2") (ok (dropped (n 2))))
!(test (note-list) ((1 found "the API needs a key")))
!(set-goal "find the key")
!(test (py-call (operator.contains (act-request) "the API needs a key")) True)
; bounded: when full, the oldest "found" note makes room
!(set-config note-max 2)
!(execute note "decision: use 2024 data")
!(test (car-atom (execute note "blocker: no access")) ok)
!(test (collapse (match &wm (note $n found $t) $t)) ())
!(test (note-count) 2)
!(set-config note-max 15)
; a successful write-file is noted automatically
!(use-script ("(plan (task t1 \"save\"))"
              "(action write-file \"{\\\"path\\\": \\\"safety_note.md\\\", \\\"content\\\": \\\"x\\\"}\")"
              "(final \"saved safety_note.md\")"))
!(run-agent "write a file")
!(test (collapse (match &wm (note $n file $t) $t)) ("wrote safety_note.md"))

; ---------------- 4. evidence ----------------
; a task whose calls all failed cannot be marked done
!(use-script ("(plan (task t1 \"fetch\"))"
              "(action always-fails \"x\")"
              "(task-done t1)"
              "(task-failed t1 \"the service is down\")"
              "(final \"could not fetch: the service is down\")"))
!(test (run-agent "fetch it") (done "could not fetch: the service is down"))
!(test (let (2 task-done (error (no-evidence $id $why))) (index-atom (outcomes) 1) $id) t1)
!(test (collapse (status-of t1)) (failed))
; a final answer does not close a task whose calls all failed
!(use-script ("(plan (task t1 \"fetch\"))"
              "(action always-fails \"x\")"
              "(final \"fetched it\")" "(final \"fetched it\")" "(final \"fetched it\")"
              "(final \"fetched it\")" "(final \"fetched it\")" "(final \"fetched it\")"))
!(test (run-agent "fetch again") (done-unverified "fetched it"))
!(test (collapse (status-of t1)) (running))
; claimed files must exist
!(test (py-call (fake_tools.claimed_files_ok)) True)
; done-unverified is not a success: never kept, and an error for a parent agent
!(test (episode-confidence (done-unverified "x")) 0)
!(test (car-atom (helper-outcome (done-unverified "draft"))) error)

; ---------------- 5. no guessing when the user does not answer ----------------
!(clear-wm)
!(record-step ask-user "which file?" (error "blank response"))
!(test (unanswered-questions) ("which file?"))
!(record-step ask-user "which file?" (ok "sales.csv"))
!(test (unanswered-questions) ())
!(use-script ("(plan (task t1 \"name the file\"))"
              "(ask-user \"which file should I use?\")"
              "(final \"I used data.csv\")"                                 ; a guess: rejected
              "(final \"Blocked: you did not answer which file to use - please tell me the file name.\")"))
!(test (run-agent "summarize my file") (blocked "Blocked: you did not answer which file to use - please tell me the file name."))
!(test (collapse (status-of t1)) (blocked))
!(test (py-call (operator.contains (repr (index-atom (outcomes) 1)) "guessing-instead-of-asking")) True)   ; the guess was rejected
!(test (collapse (match &wm (note $n blocker $t) yes)) (yes))

; ---------------- 6. every memory write is gated ----------------
!(use-script ("(plan (task t1 \"t\"))" "(action upper \"x\")" "(final \"X\")"))
!(test (run-agent "email bob@example.com the summary") (done "X"))
!(test (collapse (match &kb (fact (episode "email bob@example.com the summary" $t $a) $m) yes)) ())   ; sensitive goal: not kept
!(use-script ("(plan (task t1 \"t\"))" "(action upper \"x\")" "(final \"X\")"))
!(test (run-agent "shout x") (done "X"))
!(test (collapse (match &kb (fact (episode "shout x" $t $a) $m) yes)) (yes))   ; ordinary goal: kept

; ---------------- 7. invalid dependencies ----------------
!(test (check-plan (plan (task t1 "a" (after t1)))) (invalid (self-dependency (t1) "a task cannot come after itself")))
!(test (car-atom (index-atom (check-plan (plan (task t1 "a" (after t2)) (task t2 "b" (after t1)))) 1)) dependency-cycle)
!(test (car-atom (index-atom (check-plan (plan (task t1 "a" (after t3)) (task t2 "b" (after t1)) (task t3 "c" (after t2)))) 1)) dependency-cycle)
!(test (check-plan (plan (task t1 "a") (task t2 "b" (after t1)) (task t3 "c" (after t1 t2)))) (plan (task t1 "a") (task t2 "b" (after t1)) (task t3 "c" (after t1 t2))))
; a cyclic plan goes back to the model, which corrects it
!(use-script ("(plan (task t1 \"a\" (after t2)) (task t2 \"b\" (after t1)))"
              "(plan (task t1 \"a\") (task t2 \"b\" (after t1)))"
              "(actions (action upper \"a\") (task-done t1) (action upper \"b\"))"
              "(final \"A B\")"))
!(test (run-agent "two steps") (done "A B"))
!(test (py-call (operator.contains (last-prompt) "YOUR PREVIOUS PLAN WAS REJECTED")) False)   ; the retry was the 2nd call, not the last
!(test (collapse (match &wm (depends t2 $x) $x)) (t1))

; ---------------- 8. the whole prompt is bounded ----------------
!(test (< (py-call (fake_tools.huge_prompt_len)) 62000) True)
