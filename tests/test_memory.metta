; Tests: selective memory formation, sensitivity filter, relevance, episodes, limits.

!(import! &self ../core/agent)
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)   ; no waiting in tests
!(declare-tool upper "uppercase text" safe fake_tools.upper)

; ---------------- symbol → string (persistence safety) ----------------
!(test (get-metatype (as-string (py-call (.lower "Two Words")))) Grounded)
!(test (as-string "already a string") "already a string")
!(test (as-string 42) 42)

; ---------------- gates on learning ----------------
!(test (learn-fact (capital france paris) 0.95 gemini) (ok remembered))
!(test (learn-fact "just a sentence" 0.9 gemini) (error (rejected (not-structured))))
!(test (learn-fact (maybe true) 0.3 gemini) (error (rejected (low-confidence))))
!(test (learn-fact (x y) 1.5 gemini) (error (rejected (bad-confidence))))
; (learn-fact (x y) "high" gemini) is rejected at COMPILE time by PeTTa's type
; checker (it inferred Number from >=). Gemini's replies arrive at RUNTIME, so
; that path is tested through a real run below ("bad confidence at runtime").
!(test (learn-fact (user password "hunter2") 0.9 gemini) (error (rejected ((sensitive secret-word)))))
!(test (learn-fact (user email "bob@example.com") 0.9 gemini) (error (rejected ((sensitive email)))))
!(test (learn-fact (key "AIzaSyD-abcdefghijklmnopqrstuvwxyz12") 0.9 gemini) (error (rejected ((sensitive api-key)))))
!(test (learn-fact (card "4111 1111 1111 1111") 0.9 gemini) (error (rejected ((sensitive card-number)))))
!(set-config memory-max-chars 30)
!(test (learn-fact (note "a perfectly normal but rather long sentence") 0.9 gemini) (error (rejected (too-long))))
!(set-config memory-max-chars 300)
; several problems are all reported
!(test (learn-fact "my password" 0.1 gemini) (error (rejected (not-structured low-confidence (sensitive secret-word)))))
; nothing rejected was stored
!(test (fact-count) 1)

; ---------------- dedup / update ----------------
!(learn-fact (capital france paris) 0.7 gemini)
!(test (fact-count) 1)
!(test (recall (capital france $x)) (((capital france paris) 0.7)))

; ---------------- relevance ----------------
!(learn-fact (capital japan tokyo) 0.9 gemini)
!(learn-fact (boiling-point water 100) 0.99 gemini)
!(learn-fact (preference user answer-style short) 0.9 user)
!(test (relevant-facts "what is the capital of japan")
       (((preference user answer-style short) 0.9)       ; preferences always included
        ((capital japan tokyo) 0.9)                       ; 2 shared words
        ((capital france paris) 0.7)))                    ; 1 shared word; water not included
!(test (relevant-facts "boil some water")
       (((preference user answer-style short) 0.9) ((boiling-point water 100) 0.99)))
; top-k limit
!(set-config memory-top-k 1)
!(test (size-atom (relevant-facts "capital of japan")) 1)
!(set-config memory-top-k 8)

; ---------------- episodes: formed automatically, only for successes ----------------
!(use-script ("(plan (task t1 \"shout\"))" "(action upper \"hi\")" "(task-done t1)" "(final \"HI\")"))
!(test (run-agent "Shout   HI please") (done "HI"))
!(test (collapse (match &kb (fact (episode $g $t $a) (meta $s $time $c)) ($g $t $a $c)))
       (("shout hi please" (tools upper) "HI" 0.8)))

; a failed run leaves no episode
!(use-script ("(plan (task t1 \"x\"))" "lol" "lol" "lol"))
!(test (run-agent "something that fails") (stopped too-many-invalid-replies))
!(test (size-atom (collapse (match &kb (fact (episode $g $t $a) $m) $g))) 1)

; same goal again → replaces, not duplicates
!(use-script ("(plan (task t1 \"shout\"))" "(action upper \"hey\")" "(task-done t1)" "(final \"HEY\")"))
!(run-agent "shout hi please")
!(test (collapse (match &kb (fact (episode "shout hi please" $t $a) $m) $a)) ("HEY"))

; similar episodes are offered to the planner
!(test (similar-episodes "please shout something") (("shout hi please" (tools upper) "HEY")))
!(test (similar-episodes "boil water") ())
!(set-goal "please shout again")
!(test (py-call (operator.contains (plan-request) "shout hi please")) True)
; episodes don't clutter the facts list
!(test (py-call (operator.contains (act-request) "episode")) False)

; ---------------- learn during a run (Gemini proposal → gated) ----------------
!(use-script ("(plan (task t1 \"t\"))"
              "(learn (capital italy rome) 0.9)"
              "(learn (user password \"abc\") 0.9)"
              "(task-done t1)" "(final \"ok\")"))
!(test (run-agent "x") (done "ok"))
!(test (recall (capital italy $x)) (((capital italy rome) 0.9)))
!(test (match &wm (step $n learn (user password "abc") $o) $o) (error (rejected ((sensitive secret-word)))))
!(test (recall (user password $x)) ())

; bad confidence at runtime: a string / bool from Gemini must not crash the loop
!(use-script ("(plan (task t1 \"t\"))"
              "(learn (x y) \"high\")"
              "(learn (x z) True)"
              "(task-done t1)" "(final \"still alive\")"))
!(test (run-agent "x") (done "still alive"))
!(test (match &wm (step $n learn (x y) $o) $o) (error (rejected (bad-confidence))))
!(test (match &wm (step $n learn (x z) $o) $o) (error (rejected (bad-confidence))))

; ---------------- size limit: weakest go first ----------------
!(set-config memory-max 3)
!(learn-fact (filler a) 0.6 gemini)
!(test (fact-count) 3)
!(test (recall (filler $x)) ())                   ; lowest confidence was dropped
!(test (recall (boiling-point water $x)) (((boiling-point water 100) 0.99)))
!(set-config memory-max 500)

!(test (car-atom (memory-stats)) memory)

; persistence of everything learned here (checked in test_memory_reload)
!(save-space &kb "data/test_memory_kb.metta")
