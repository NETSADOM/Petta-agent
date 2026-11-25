; Integration tests: complete workflows through the real pieces —
; skills, plan, tools + gates, retry, memory, verification, the pretty renderer,
; and cancellation. Only Gemini is scripted.
; stdin: "y" approves the one approval request.

!(import! &self ../core/agent)
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)
!(set-config ui pretty)                     ; render through core/ui.py like the CLI

!(declare-tool upper "uppercase text" safe fake_tools.upper)
!(declare-tool flaky-ok "fails twice, then works" safe fake_tools.flaky_then_ok)
!(declare-tool write-note "save a note" needs-approval fake_tools.write_note)
!(declare-tool long-job "takes a while" safe fake_tools.press_cancel)
!(declare-skill shouting "make text loud" (upper) (shout loud))
!(set-skill-info shouting procedure "1. upper the text 2. report it")
!(declare-verifier fake_tools.has_digit)

; ---------------- workflow 1: everything working together ----------------
; skill discovery → plan with (uses ..) → retry → approval → learn → verify → episode
!(use-script ("(plan (task t1 \"shout the word\" (uses shouting)) (task t2 \"fetch data\" (after t1)) (task t3 \"save note\" (after t2)))"
              "(action upper \"hello\")"
              "(task-done t1)"
              "(action flaky-ok \"data\")"
              "(task-done t2)"
              "(action write-note \"HELLO 3\")"
              "(task-done t3)"
              "(learn (greeting-word hello) 0.9)"
              "(final \"HELLO, fetched on try 3, note saved\")"))
!(test (run-agent "shout hello loud, fetch data, save a note") (done "HELLO, fetched on try 3, note saved"))
!(py-call (ui.show_result (done "HELLO, fetched on try 3, note saved")))
!(test (collapse (match &wm (task $i $d $s) $s)) (completed completed completed))
!(test (skills-of-task t1) (shouting))
!(test (match &wm (retried flaky-ok "data" $k) $k) 2)
!(test (match &wm (approval write-note $i $y) $y) true)
!(test (recall (greeting-word $x)) (((greeting-word hello) 0.9)))
!(test (match &wm (verification 1 objective $r) $r) pass)
!(test (size-atom (similar-episodes "shout hello again")) 1)
!(test (recall (fix (fails flaky-ok $c) $h)) (((fix (fails flaky-ok temporary) retry) 0.7)))

; ---------------- workflow 2: cancellation ----------------
!(use-script ("(plan (task t1 \"long work\") (task t2 \"more work\" (after t1)))"
              "(action long-job \"x\")"          ; "you press c" during this tool
              "(action upper \"never runs\")"
              "(final \"never\")"))
!(test (run-agent "a long job") (cancelled))
!(py-call (ui.show_result (cancelled)))
!(test (sort-atom (collapse (match &wm (task $i $d $s) ($i $s)))) ((t1 cancelled) (t2 cancelled)))
!(test (step-count) 1)                         ; the next action never ran
!(test (similar-episodes "a long job") ())     ; cancelled runs leave no episode

; ---------------- workflow 3: stop reasons are rendered, never a crash ----------------
!(use-script ("(plan (task t1 \"t\"))" "lol" "lol" "lol"))
!(let $r (run-agent "x") (py-call (ui.show_result $r)))
!(use-script ("(plan (task t1 \"t\"))" "(task-done t1)" "(final \"no digits\")" "(final \"still none\")" "(final \"nope\")"))
!(let $r (run-agent "x") (test (car-atom $r) done-unverified))
