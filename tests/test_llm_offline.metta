; Offline tests: no network, no API key needed.
; Uses canned "Gemini replies" to test parsing, validation and plan loading.

!(import! &self ../core/schema)
!(import! &self ../core/llm)

!(add-atom &caps (tool calc "evaluate arithmetic" safe))
!(add-atom &caps (tool web-search "search the web" safe))

; ---------------- parsing replies ----------------
!(test (parse-reply "(final \"done\")") (final "done"))
; code fences and chatter around the expression are stripped
!(test (parse-reply "Sure! ```lisp\n(action calc \"2+3\")\n``` hope that helps")
       (action calc "2+3"))
; parentheses inside strings don't confuse the extractor
!(test (parse-reply "(final \"a (nested) answer\")") (final "a (nested) answer"))
!(test (parse-reply "I think the answer is 5") (invalid no-expression))
!(test (parse-reply "(final \"unclosed") (invalid no-expression))

; ---------------- validating proposals ----------------
!(test (check-proposal (action calc "2+3")) (action calc "2+3"))
; unknown tool: well-formed, passed on — (execute ..) answers it with an error the model reads
!(test (check-proposal (action rm-rf "/")) (action rm-rf "/"))
!(test (check-proposal (action "rm-rf" "/")) (invalid bad-shape))
; several calls in one reply
!(test (check-proposal (actions (action calc "1") (action rm-rf "/"))) (actions (action calc "1") (action rm-rf "/")))
!(test (check-proposal (actions (final "x") (final "y"))) (actions (final "x") (final "y")))   ; the first final ends the batch (agent.metta)
; write-file with path and content as TWO strings becomes the JSON input (one escaping level)
!(test (check-proposal (action write-file "a.md" "two words")) (action write-file "{\"path\": \"a.md\", \"content\": \"two words\"}"))
!(test (check-proposal (parse-reply "(action write-file \"a.md\" \"say \\\"hi\\\"\")"))
       (action write-file "{\"path\": \"a.md\", \"content\": \"say \\\"hi\\\"\"}"))
; ... also inside a batch
!(test (check-proposal (actions (action write-file "b.md" "x") (final "saved b.md")))
       (actions (action write-file "{\"path\": \"b.md\", \"content\": \"x\"}") (final "saved b.md")))
; the JSON form still works, and other tools still take ONE input
!(test (check-proposal (action write-file "{\"path\": \"c.md\", \"content\": \"y\"}")) (action write-file "{\"path\": \"c.md\", \"content\": \"y\"}"))
!(test (check-proposal (action calc "1" "2")) (invalid bad-shape))
!(test (check-proposal (actions)) (invalid bad-shape))
!(test (parse-reply "(action calc \"1+1\")\n(action calc \"2+2\")") (actions (action calc "1+1") (action calc "2+2")))
!(test (parse-reply "(actions (action calc \"1\") (action now \"\"))") (actions (action calc "1") (action now "")))
!(test (parse-reply "[{\"tool\": \"calc\", \"input\": \"1\"}, {\"tool\": \"now\", \"input\": \"\"}]") (actions (action calc "1") (action now "")))
; one action among prose and a final: still the first form, as before
!(test (parse-reply "(final \"a\") (action calc \"1\")") (final "a"))
; parentheses in the prose before the reply are not the reply
!(test (parse-reply "I will read it (carefully) now.\n(action read-file \"a.txt\")") (action read-file "a.txt"))
!(test (parse-reply "Done (see above). (final \"x\")") (final "x"))
; a task-done next to ONE action: both run, in order
!(test (parse-reply "(task-done t1) (action calc \"2\")") (actions (task-done t1) (action calc "2")))
!(test (check-proposal (parse-reply "(task-done t1) (action calc \"2\")")) (actions (task-done t1) (action calc "2")))
; a batch may end with a final
!(test (check-proposal (parse-reply "(task-done t2) (final \"done\")")) (actions (task-done t2) (final "done")))
!(test (check-proposal (actions (action calc "1") (final "a"))) (actions (action calc "1") (final "a")))
!(test (check-proposal (actions (action calc "1") (final "a" "b"))) (invalid bad-shape))
; task-done takes ids only: a note added to it is dropped, not the whole reply
!(test (parse-reply "(task-done t1 \"found it\")") (task-done t1))
!(test (check-proposal (parse-reply "(actions (task-done t1 \"Dropout is (a) technique\") (action calc \"1\"))"))
       (actions (task-done t1) (action calc "1")))
; a final with unescaped quotes inside is ONE string, balanced or not
!(test (parse-reply "(final \"Dropout \"drops\" units\")") (final "Dropout \"drops\" units"))
!(test (parse-reply "Here: (final \"a 5\" screen\")") (final "a 5\" screen"))
!(test (parse-reply "(ask-user \"which \"file\"?\")") (ask-user "which \"file\"?"))
!(test (check-proposal (final "42")) (final "42"))
!(test (check-proposal (ask-user "which file?")) (ask-user "which file?"))
!(test (check-proposal (action calc)) (invalid bad-shape))
!(test (check-proposal (run-shell "ls")) (invalid bad-shape))
!(test (check-proposal hello) (invalid bad-shape))
!(test (check-proposal (parse-reply "no sexpr here")) (invalid no-expression))

; ---------------- validating plans ----------------
!(test (check-plan (plan (task t1 "a") (task t2 "b" (after t1))))
       (plan (task t1 "a") (task t2 "b" (after t1))))
!(test (check-plan (plan)) (invalid empty-plan))
!(test (check-plan (steps (task t1 "a"))) (invalid not-a-plan))
!(test (check-plan (plan (task t1 "a") (job t2 "b"))) (invalid bad-task))
!(test (check-plan (plan (task t1 "a") (task t2 "b" (before t1)))) (invalid bad-task))
!(test (check-plan (plan (task t1 "a") (task t1 "b"))) (invalid duplicate-ids))
!(test (check-plan (plan (task t1 "a") (task t2 "b" (after t9)))) (invalid unknown-dependency))

; ---------------- loading a plan into &wm ----------------
!(test (load-plan (plan (task t1 "search population of paris")
                        (task t2 "search population of rome")
                        (task t3 "add them" (after t1 t2)))) 3)
!(test (ready-tasks) (t1 t2))
!(set-status t1 completed)
!(test (ready-tasks) (t2))
!(set-status t2 completed)
!(test (ready-tasks) (t3))

; loading a new plan replaces the old one (no leftover tasks/deps)
!(test (load-plan (plan (task t1 "only task"))) 1)
!(test (collapse (match &wm (task $i $d $s) ($i $s))) ((t1 pending)))
!(test (collapse (match &wm (depends $a $b) $a)) ())

; ---------------- prompts carry the context ----------------
!(set-goal "what is 2+3")
!(remember (capital france paris) user 0.9)
!(test (py-call (operator.contains (plan-request) "what is 2+3")) True)
!(test (py-call (operator.contains (plan-request) "web-search")) True)
; only RELEVANT facts reach the model
!(test (py-call (operator.contains (act-request) "capital france paris")) False)
!(set-goal "what is the capital of france")
!(test (py-call (operator.contains (act-request) "capital france paris")) True)
!(set-goal "what is 2+3")
!(test (py-call (operator.contains (act-request) "only task")) True)
; untrusted data is fenced off from instructions
!(test (py-call (operator.contains (act-request) "<data name=\"goal\">")) True)
; every tool is a readable line; one with an example also shows an EXACT call to copy
!(add-atom &caps (tool-setting calc example "2480*0.15"))
!(test (py-call (operator.contains (act-request) "- web-search [safe]: search the web")) True)
!(test (py-call (operator.contains (act-request) "call: (action calc \"2480*0.15\")")) True)
!(test (py-call (operator.contains (plan-request) "call: (action calc \"2480*0.15\")")) True)
; the current task's skill tools are named inside the CURRENT TASK block
!(add-atom &caps (skill-needs offline-math calc))
!(add-atom &wm (task-skill t1 offline-math))
!(test (task-tool-rows t1) ((calc "evaluate arithmetic" safe "2480*0.15")))
!(remove-atom &wm (task-skill t1 offline-math))

; ---------------- no API key → permanent config error, no crash ----------------
!(test (car-atom (ask-llm "sys" "hi")) error)
!(test (index-atom (ask-llm "sys" "hi") 1) config)
!(test (temporary-error config) False)
!(test (temporary-error rate-limit) True)
!(test (car-atom (propose-next)) error)
