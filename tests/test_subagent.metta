; Sub-agents: (action delegate "sub-task") runs a HELPER agent with a fresh
; context and returns its answer as the tool result; the parent's working memory
; is restored afterwards. The scripted brain is one queue of replies, used by
; parent and helper in the order they ask. Also: offline parsing of web-search.

!(import! &self ../core/agent)
!(import! &self ../my_capabilities)
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)
!(declare-tool upper "uppercase text" safe fake_tools.upper)

(= (outcomes) (collapse (match &wm (step $n $t $i $o) ($n $t $o))))

; ---------------- a helper does a sub-task; the parent carries on ----------------
!(use-script ("(plan (task t1 \"get the word shouted\"))"     ; parent plan
              "(action upper \"before\")"                     ; parent turn 1
              "(action delegate \"shout the word helper\")"   ; parent turn 2 → helper:
              "(plan (task t1 \"shout\"))"                    ;   helper plan
              "(action upper \"helper\")"                     ;   helper turn 1
              "(task-done t1)"                                ;   helper turn 2
              "(final \"HELPER\")"                            ;   helper turn 3
              "(task-done t1)"                                ; parent turn 3
              "(final \"the helper said HELPER\")"))          ; parent turn 4
!(test (run-agent "the parent goal") (done "the helper said HELPER"))
; the parent's own history is intact; the helper's steps are not in it
!(test (repr (outcomes)) "((1 upper (ok BEFORE)) (2 delegate (ok \"HELPER\")) (3 task-done (ok completed)))")
!(test (goal-text) "the parent goal")
!(test (current-turn) 4)
; settings are back to the main agent's
!(test (config-value agent-depth) 0)
!(test (config-value max-iterations) 40)
; only the parent goal is a session task
!(test (py-call (operator.contains (py-call (session.summary)) "shout the word helper")) False)

; ---------------- a helper cannot start a helper ----------------
!(use-script ("(plan (task t1 \"t\"))"
              "(action delegate \"do a sub-task\")"
              "(plan (task t1 \"sub\"))"
              "(action delegate \"deeper\")"                 ; refused inside the helper
              "(task-done t1)"
              "(final \"did it myself\")"
              "(task-done t1)"
              "(final \"ok\")"))
!(test (run-agent "nesting") (done "ok"))
!(test (repr (outcomes)) "((1 delegate (ok \"did it myself\")) (2 task-done (ok completed)))")

; ---------------- a helper that gets stuck → an error the parent can read ----------------
!(set-config sub-agent-turns 2)
!(use-script ("(plan (task t1 \"t\"))"
              "(action delegate \"loop forever\")"
              "(plan (task t1 \"loop\"))"
              "(action upper \"a\")" "(action upper \"b\")"   ; helper: 2 turns, then its limit
              "(action upper \"parent does it\")"            ; parent recovers
              "(task-done t1)"
              "(final \"PARENT DOES IT\")"))
!(test (run-agent "stuck helper") (done "PARENT DOES IT"))
!(test (let (1 delegate (error (helper-stopped (iteration-limit $p)))) (index-atom (outcomes) 0) ok) ok)
!(test (repr (index-atom (outcomes) 1)) "(2 upper (ok PARENT DOES IT))")
!(set-config sub-agent-turns 20)

; ---------------- web-search: parsing a saved results page (no network) ----------------
!(test (py-call (operator.eq (py-call (fake_tools.ddg_fixture_titles))
                             "unittest — Unit testing framework | https://docs.python.org/3/library/unittest.html | The unittest unit testing framework was inspired by JUnit. || Python Unittest Tutorial | https://example.org/unittest | A tutorial."))
       True)
!(test (car-atom (py-call (agent_tools.web_search "   "))) error)
!(test (tool-known web-search) True)
