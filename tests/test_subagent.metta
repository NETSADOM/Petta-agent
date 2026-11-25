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

; ---------------- a helper is not offered delegate (it cannot use it) ----------------
(= (offers $tool) (not (== (collapse (let $all (prompt-tool-catalog)
                                          (let $t (superpose $all) (if (== (car-atom $t) $tool) yes (empty)))))
                           ())))
!(test (offers delegate) False)                ; off by default
!(set-config delegate on)
!(test (offers delegate) True)
!(set-config agent-depth 1)
!(test (offers delegate) False)
!(test (offers upper) True)
!(set-config agent-depth 0)
!(set-config delegate off)

; ---------------- an approval you gave is remembered: a helper does not ask again ----------------
; stdin is /dev/null here, so ANY question would be answered "no".
!(declare-tool fetch-page "get a page" needs-approval fake_tools.upper)
!(set-tool-option fetch-page remember-approval yes)
!(py-call (io_helper.remember_approval fetch-page "http://example.org/a"))
!(use-script ("(plan (task t1 \"t\"))"
              "(action delegate \"read the page\")"
              "(plan (task t1 \"read\"))"
              "(action fetch-page \"http://example.org/a\")"   ; approved before → runs
              "(action fetch-page \"http://example.org/b\")"   ; never approved → asked → no
              "(final \"read A\")"
              "(task-done t1)"
              "(final \"ok\")"))
!(test (run-agent "remembered approval") (done "ok"))
!(test (py-call (io_helper.approved_before fetch-page "http://example.org/a")) True)
!(test (py-call (io_helper.approved_before fetch-page "http://example.org/b")) False)
; a tool without remember-approval is always asked
!(test (approved-before write-file "x") False)
!(py-call (io_helper.forget_approvals))

; ---------------- the same long result twice → flagged as going in circles ----------------
!(declare-tool chatty "long output" safe fake_tools.chatty)
!(use-script ("(plan (task t1 \"t\"))"
              "(action chatty \"a\")"
              "(action chatty \"b\")"                        ; same 10000-char output
              "(action upper \"short\")" "(action upper \"short\")"   ; short: not flagged
              "(task-done t1)"
              "(final \"done\")"))
!(test (run-agent "circles") (done "done"))
!(test (let (1 chatty (ok $x)) (index-atom (outcomes) 0) (is-expression $x)) False)
!(test (let (2 chatty (ok (repeated-result (same-as-steps $p) $hint $x))) (index-atom (outcomes) 1) $p) (1))
!(test (repr (index-atom (outcomes) 3)) "(4 upper (ok SHORT))")

; ---------------- a web page becomes its readable text ----------------
!(test (py-call (fake_tools.html_fixture_ok)) True)

; ---------------- the latest turn's results are shown (nearly) in full ----------------
(= (steps-chars) (py-call (toolrunner.length (steps-repr))))
!(clear-wm)
!(set-turn 1)
!(record-step chatty "page" (ok (py-call (fake_tools.long_text 9000))))
!(set-turn 2)                                   ; the model now sees step 1 for the first time
!(test (> (steps-chars) 8000) True)
!(set-turn 3)                                   ; seen once: back to the short form
!(test (< (steps-chars) 1500) True)
!(clear-wm)

; ---------------- a skill called as a tool loads the skill ----------------
!(use-script ("(plan (task t1 \"sum up\"))"
              "(action summarization \"notes.txt\")"
              "(task-done t1)"
              "(final \"done\")"))
!(test (run-agent "skill as tool") (done "done"))
!(test (let (1 summarization (ok (skill-not-tool summarization $why $r))) (index-atom (outcomes) 0) ok) ok)

; ---------------- speed fixes, Python side (arxiv-search, PDFs, quota, approvals) ----------------
!(test (py-call (fake_tools.speed_fixes_ok)) True)
!(test (tool-known arxiv-search) True)
!(test (needs-approval arxiv-search) False)

; ---------------- web-search: parsing a saved results page (no network) ----------------
!(test (py-call (operator.eq (py-call (fake_tools.ddg_fixture_titles))
                             "unittest — Unit testing framework | https://docs.python.org/3/library/unittest.html | The unittest unit testing framework was inspired by JUnit. || Python Unittest Tutorial | https://example.org/unittest | A tutorial."))
       True)
!(test (car-atom (py-call (agent_tools.web_search "   "))) error)
!(test (tool-known web-search) True)
